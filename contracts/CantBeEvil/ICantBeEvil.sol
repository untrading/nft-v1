// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.8;

interface ICantBeEvil {
    function getLicenseURI(uint256 tokenId) external view returns(string memory);

    function getLicenseName(uint256 tokenId) external view returns(string memory);
}