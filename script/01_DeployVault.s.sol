// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {Vault} from "../src/Vault.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 *
 * Step 1: Deploy
 * forge script script/01_DeployVault.s.sol:DeployVaultScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 *
 * Step 2: Proceed to poolOwner contract and call vault.acceptOwnership
 */
contract DeployVaultScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-CORE/VAULT/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        /// @dev prepare the payload to transfer ownership from deployment contract to real deployer address
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, deployer);

        address vault = factory.deploy(
            getDeploymentSalt(),
            type(Vault).creationCode,
            keccak256(type(Vault).creationCode),
            0,
            afterDeploymentExecutionPayload,
            0
        );

        /// @notice accept ownership so that in the following steps,
        /// the deployer address has right to register apps onto the vault
        Vault(vault).acceptOwnership();

        /// @notice transfer ownership to the pool owner,
        /// in 2-step process this won't take effect until new owner accepts the ownership
        /// Hence, this won't block the deployment process
        Ownable(vault).transferOwnership(getAddressFromConfig("poolOwner"));

        console.log("Vault contract deployed at ", vault);

        vm.stopBroadcast();
    }
}
