// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {ProtocolFeeController} from "../src/ProtocolFeeController.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IProtocolFees} from "../src/interfaces/IProtocolFees.sol";

/**
 * Step 1: Deploy
 * forge script script/05_DeployBinProtocolFeeController.s.sol:DeployBinProtocolFeeControllerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 *
 * Step 2: Proceed to poolOwner contract and call protocolFeeController.acceptOwnership
 */
contract DeployBinProtocolFeeControllerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-CORE-CORE/BinProtocolFeeController/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        console.log("binPoolManager address: ", address(binPoolManager));

        /// @dev append the binPoolManager address to the creationCode
        bytes memory creationCode =
            abi.encodePacked(type(ProtocolFeeController).creationCode, abi.encode(binPoolManager));

        /// @dev prepare the payload to transfer ownership from deployer to real owner
        bytes memory afterDeploymentExecutionPayload = abi.encodeWithSelector(
            Ownable.transferOwnership.selector, getAddressFromConfig("protocolFeeControllerOwner")
        );

        address binProtocolFeeController = factory.deploy(
            getDeploymentSalt(), creationCode, keccak256(creationCode), 0, afterDeploymentExecutionPayload, 0
        );

        console.log("BinProtocolFeeController contract deployed at ", binProtocolFeeController);

        /// @notice set the protocol fee controller for the clPoolManager
        IProtocolFees(binPoolManager).setProtocolFeeController(ProtocolFeeController(binProtocolFeeController));

        vm.stopBroadcast();
    }
}
