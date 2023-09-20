// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.8;

import {SolidStateERC721} from "@solidstate/contracts/token/ERC721/SolidStateERC721.sol";
import {ERC721MetadataStorage} from "@solidstate/contracts/token/ERC721/metadata/ERC721MetadataStorage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "@prb/math/contracts/PRBMathUD60x18.sol";

import "@drad/eip-5173-diamond/contracts/nFR/nFR.sol";

import {CounterStorage} from "../utils/CounterStorage.sol";

import "../oTokens/oTokenStorage.sol";
import "../wrapping/WrappingStorage.sol";

import "../management/Management.sol";
import "../CantBeEvil/CantBeEvil.sol";
import "./IunFacet.sol";

/*** EIP-712 for Unwrapping ***/
bytes32 constant EIP712DOMAINTYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");

bytes32 constant NAME_HASH = keccak256("untrading Shared NFT Smart Contract");

bytes32 constant VERSION_HASH = keccak256("1");

bytes32 constant TXTYPE_HASH = keccak256("Unwrap(uint256 tokenId)");

// keccak256("untradingsharednft")
bytes32 constant SALT = 0x48cdc51538d5c18ef784aab525d9823a2119e55be5a1288a7a9c675f0f202bdd;

contract unFacet is nFR, CantBeEvil, Management, IunFacet, IERC721Receiver {
    using CounterStorage for CounterStorage.Layout;

    using PRBMathUD60x18 for uint256;

    bytes32 immutable DOMAIN_SEPARATOR; // EIP-712 for Unwrapping

    constructor(address diamond) {
        DOMAIN_SEPARATOR = keccak256(abi.encode(EIP712DOMAINTYPE_HASH, NAME_HASH, VERSION_HASH, block.chainid, diamond, SALT)); // 2 options, supply unDiamond address to constructor and use that instead of `this` Or use `this` and update signing obj every new facet in prod
    }

    function getORInfo(uint256 tokenId) external view override returns (uint256 ORatio, uint256 rewardRatio, address[] memory holders) {
        oTokenStorage.Layout storage o = oTokenStorage.layout();
        return (o._oTokens[tokenId].ORatio, o._oTokens[tokenId].rewardRatio, o._oTokens[tokenId].holders);
    }

    function getAllottedOR(address account) external view override returns (uint256) {
        oTokenStorage.Layout storage o = oTokenStorage.layout();
        return (o._allottedOR[account]);
    }

    function balanceOfOTokens(uint256 tokenId, address account) external view override returns (uint256) {
        oTokenStorage.Layout storage o = oTokenStorage.layout();
        return (o._oTokens[tokenId].amount[account]);
    }

    function getWrappedInfo(uint256 tokenId) external view override returns (address, uint256, bool) {
        WrappingStorage.Layout storage w = WrappingStorage.layout();
        return (w._wrappedTokens[tokenId].underlyingTokenAddress, w._wrappedTokens[tokenId].underlyingTokenId, w._wrappedTokens[tokenId].isWrapped);
    }

    function mint(
        address recipient,
        uint8 numGenerations,
        uint256 rewardRatio,
        uint256 ORatio,
        uint8 license,
        string memory tokenURI
    ) public override returns(uint256 tokenId) { //? Maybe add an oTokenReceiver param, for mint/wrap - could be an array
        require(numGenerations >= 5 && numGenerations <= 20, "numGenerations must be between 5 and 20");
        require(rewardRatio >= 5e16 && rewardRatio <= 5e17, "rewardRatio must be between 5% and 50%");
        require(ORatio >= 5e16 && ORatio <= 5e17, "ORatio must be between 5% and 50%");

        uint256 successiveRatio = ((uint256(numGenerations) * 1e18).div((uint256(numGenerations) * 1e18) - 1.618e18)) / 100 * 100; // by ( / 100 * 100) we are effectively rounding down the successive ratio. The division takes advantage of Solidity's automatic decimal truncation, effectively removing the last 2 digits, then the multiplication adds those 2 digits back as 0s.
        uint256 percentOfProfit = rewardRatio.mul(1e18 - ORatio);

        ORatio = rewardRatio.mul(ORatio);

        CounterStorage.incrementTokenId();

        uint256 newItemId = CounterStorage.layout().tokenIds;
        _distributeOTokens(newItemId, recipient, ORatio, rewardRatio);
        _mint(recipient, newItemId, numGenerations, percentOfProfit, successiveRatio);
        
        _setTokenURI(newItemId, tokenURI);
        _setTokenLicense(newItemId, license);

        tokenId = newItemId;
    }

    function wrap( // Add a to/recipient param
        address token, 
        uint256 tokenId, 
        uint8 numGenerations,
        uint256 rewardRatio,
        uint256 ORatio,
        uint8 license,
        string memory tokenURI
    ) external override {
        require(token != address(this), "Cannot wrap a token from this contract");

        uint256 newItemId = mint(_msgSender(), numGenerations, rewardRatio, ORatio, license, tokenURI);

        WrappingStorage.Layout storage w = WrappingStorage.layout();

        w._wrappedTokens[newItemId] = WrappingStorage.Wrapped(token, tokenId, true);

        IERC721(token).safeTransferFrom(_msgSender(), address(this), tokenId);
    }

    function unwrap(uint256 tokenId, uint8 sigV, bytes32 sigR, bytes32 sigS) external override { // Add a to/recipient param, also add an additional param to signature to make it more distinct and unique
        nFRStorage.Layout storage n = nFRStorage.layout();
        WrappingStorage.Layout storage w = WrappingStorage.layout();

        require(_isApprovedOrOwner(_msgSender(), tokenId), "Caller is not owner of token");
        require(w._wrappedTokens[tokenId].isWrapped == true, "Token is not wrapped");

        if (n._tokenFRInfo[tokenId].ownerAmount != 1) {
            bytes32 inputHash = keccak256(abi.encode(TXTYPE_HASH, tokenId));
            bytes32 totalHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, inputHash));

            address recovered = ecrecover(totalHash, sigV, sigR, sigS);

            ManagementStorage.Layout storage m = ManagementStorage.layout();
            oTokenStorage.Layout storage o = oTokenStorage.layout();

            oTokenStorage.oToken storage oToken = o._oTokens[tokenId];

            address largestOTokenHolder;

            for (uint i = 0; i < oToken.holders.length; i++) {
                if (oToken.amount[oToken.holders[i]] > oToken.amount[largestOTokenHolder]) { // Only forseeable problem is if the oToken holders are split or tied, e.g. [0.1, 0.45, 0.45] In this config only the middle address' sig would be approved.
                    largestOTokenHolder = oToken.holders[i];
                }
            }

            require(recovered == m.untradingManager || recovered == largestOTokenHolder, "Invalid signature provided");
        }

        address underlyingTokenAddress = w._wrappedTokens[tokenId].underlyingTokenAddress;
        uint256 underlyingTokenId = w._wrappedTokens[tokenId].underlyingTokenId;

        _burn(tokenId);

        IERC721(underlyingTokenAddress).safeTransferFrom(address(this), _msgSender(), underlyingTokenId);
    }

    function releaseOR(address payable account) external override {
        oTokenStorage.Layout storage o = oTokenStorage.layout();
        require(o._allottedOR[account] > 0, "No OR Payment due");

        uint256 ORAmount = o._allottedOR[account];

        o._allottedOR[account] = 0;

        (bool sent, ) = account.call{value: ORAmount}("");
        require(sent, "Failed to release OR");

        emit ORClaimed(account, ORAmount);
    }

    function transferOTokens(uint256 tokenId, address recipient, uint256 amount) external override {
        oTokenStorage.Layout storage o = oTokenStorage.layout();

        require(recipient != address(0), "transfer to the zero address");
        require(recipient != _msgSender(), "transfer to self");
        require(amount > 0, "transfer amount is 0");

        uint256 fromBalance = o._oTokens[tokenId].amount[_msgSender()];
        require(fromBalance >= amount, "transfer amount exceeds balance");

        unchecked {
             o._oTokens[tokenId].amount[_msgSender()] = fromBalance - amount;
            // Overflow not possible: the sum of all balances is capped by 1e18 (100%), and is preserved by
            // decrementing then incrementing.
             o._oTokens[tokenId].amount[recipient] += amount;
        }

        if (fromBalance - amount == 0) {
            for (uint256 i = 0; i < o._oTokens[tokenId].holders.length; i++) {
                if (o._oTokens[tokenId].holders[i] == _msgSender()) {
                    o._oTokens[tokenId].holders[i] = recipient;
                    return;
                }
            }
            revert("Not Found");
        } else {
            o._oTokens[tokenId].holders.push(recipient);
        }

        emit OTokenTransfer(_msgSender(), recipient, tokenId);
    }

    function _distributeOTokens(uint256 tokenId, address recipient, uint256 ORatio, uint256 rewardRatio) internal {
        oTokenStorage.Layout storage o = oTokenStorage.layout();
        ManagementStorage.Layout storage m = ManagementStorage.layout();
        
        o._oTokens[tokenId].ORatio = ORatio;
        o._oTokens[tokenId].rewardRatio = rewardRatio;
        o._oTokens[tokenId].holders = [m.untradingManager, recipient];
        o._oTokens[tokenId].amount[m.untradingManager] = m.managerCut;
        o._oTokens[tokenId].amount[recipient] = (1e18 - m.managerCut);

        emit OTokensDistributed(tokenId);
    }

    function _distributeOR(uint256 tokenId, uint256 soldPrice) internal {
        nFRStorage.Layout storage n = nFRStorage.layout();
        oTokenStorage.Layout storage o = oTokenStorage.layout();

        uint256 profit = soldPrice - n._tokenFRInfo[tokenId].lastSoldPrice;
        uint256 ORAvailable = profit.mul(o._oTokens[tokenId].ORatio);

        for (uint holder = 0; holder < o._oTokens[tokenId].holders.length; holder++) {
            address holderAddress = o._oTokens[tokenId].holders[holder];
            o._allottedOR[holderAddress] += ORAvailable.mul(o._oTokens[tokenId].amount[holderAddress]);
        }

        emit ORDistributed(tokenId, soldPrice, ORAvailable);
    }

    function _distributeFR(uint256 tokenId, uint256 soldPrice) internal override returns(uint256 allocatedFR) {
        _distributeOR(tokenId, soldPrice);
        uint256 allocated = super._distributeFR(tokenId, soldPrice);

        nFRStorage.Layout storage n = nFRStorage.layout();
        oTokenStorage.Layout storage o = oTokenStorage.layout();

        uint256 profit = soldPrice - n._tokenFRInfo[tokenId].lastSoldPrice;

        allocatedFR = (allocated + profit.mul(o._oTokens[tokenId].ORatio));
    }

    function _burn(uint256 tokenId) internal override {
        super._burn(tokenId);
        oTokenStorage.Layout storage o = oTokenStorage.layout();
        WrappingStorage.Layout storage w = WrappingStorage.layout();

        delete o._oTokens[tokenId];
        delete w._wrappedTokens[tokenId];
        // Need to delete licenses here
    }

    function _setTokenURI(uint256 tokenId, string memory tokenURI) internal {
        ERC721MetadataStorage.Layout storage l = ERC721MetadataStorage.layout();
        l.tokenURIs[tokenId] = tokenURI;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
