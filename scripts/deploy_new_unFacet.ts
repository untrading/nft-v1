import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ethers, deployments, getNamedAccounts } from "hardhat";

/**
 * Deploys a new unFacet, supposed to be used before calling upgrade_unDiamond
 */
const main = async () => {  
    const { deploy, get } = deployments;

    const { deployer } = await getNamedAccounts();
    
    await deploy("unFacet", {
        from: deployer,
        args: [ (await get("unDiamond")).address ],
    });
};

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});