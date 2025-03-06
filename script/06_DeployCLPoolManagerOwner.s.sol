// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {BaseScript} from "./BaseScript.sol";
import {CLPoolManagerOwner} from "../src/pool-cl/CLPoolManagerOwner.sol";

/**
 * Step 1: Deploy
 * forge script script/06_DeployCLPoolManagerOwner.s.sol:DeployCLPoolManagerOwnerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 *
 * Step 2: (Manual) Ask 'poolOwner' proceed to CLPoolManagerOwner.acceptOwnership
 *
 * Step 3: (Manual) Proceed to call clPoolManager.transferOwnership(clPoolManagerOwner)
 */
contract DeployCLPoolManagerOwnerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-CORE/CLPoolManagerOwner/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolOwner = getAddressFromConfig("poolOwner");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        console.log("clPoolManager address: ", address(clPoolManager));

        /// @dev append the poolManager address to the creationCode
        bytes memory creationCode = abi.encodePacked(type(CLPoolManagerOwner).creationCode, abi.encode(clPoolManager));

        /// @dev prepare the payload to transfer ownership from deployment contract to poolOwner address
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, poolOwner);

        address clPoolManagerOwner = factory.deploy(
            getDeploymentSalt(), creationCode, keccak256(creationCode), 0, afterDeploymentExecutionPayload, 0
        );
        console.log("CLPoolManagerOwner contract deployed at ", clPoolManagerOwner);

        vm.stopBroadcast();
    }
}
