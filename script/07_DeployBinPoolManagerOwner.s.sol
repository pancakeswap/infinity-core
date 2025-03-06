// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {BaseScript} from "./BaseScript.sol";
import {BinPoolManagerOwner} from "../src/pool-bin/BinPoolManagerOwner.sol";

/**
 * Step 1: Deploy
 * forge script script/07_DeployBinPoolManagerOwner.s.sol:DeployBinPoolManagerOwnerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 *
 * Step 2: (Manual) Ask 'poolOwner' proceed to BinPoolManagerOwner.acceptOwnership
 *
 * Step 3: (Manual) Proceed to call binPoolManager.transferOwnership(binPoolManagerOwner)
 */
contract DeployBinPoolManagerOwnerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-CORE/BinPoolManagerOwner/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolOwner = getAddressFromConfig("poolOwner");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        console.log("binPoolManager address: ", address(binPoolManager));

        /// @dev append poolManager address to the creationCode
        bytes memory creationCode = abi.encodePacked(type(BinPoolManagerOwner).creationCode, abi.encode(binPoolManager));

        /// @dev prepare the payload to transfer ownership from deployment contract to poolOwner address
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, poolOwner);

        address binPoolManagerOwner = factory.deploy(
            getDeploymentSalt(), creationCode, keccak256(creationCode), 0, afterDeploymentExecutionPayload, 0
        );
        console.log("BinPoolManagerOwner contract deployed at ", binPoolManagerOwner);

        vm.stopBroadcast();
    }
}
