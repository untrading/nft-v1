import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { Selectors, FacetCutAction } from '../test/libraries/diamond';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
	const { deployments, getNamedAccounts, ethers } = hre;
	const { execute, get } = deployments;

	const { deployer } = await getNamedAccounts();

    const unFacet = await ethers.getContractAt("unFacet", (await get('unFacet')).address);

    const cut = [{ target: unFacet.address, action: FacetCutAction.Add, selectors: new Selectors(unFacet).remove(['supportsInterface(bytes4)']) }];

	await execute('unDiamond', {from: deployer}, 'diamondCut', cut, ethers.constants.AddressZero, "0x");
};

export default func;
func.tags = ["DiamondCutAdd"];
