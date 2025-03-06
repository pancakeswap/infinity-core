// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 *
 * forge script script/06_TransferPoolManagerOwner.s.sol:TransferPoolManagerOwner -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 */
contract TransferPoolManagerOwner is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        address binPoolManager = getAddressFromConfig("binPoolManager");
        address poolOwner = getAddressFromConfig("poolOwner");

        Ownable(clPoolManager).transferOwnership(poolOwner);
        console.log("clPoolManager Ownership transferred to ", address(poolOwner));

        Ownable(binPoolManager).transferOwnership(poolOwner);
        console.log("binPoolManager Ownership transferred to ", address(poolOwner));

        vm.stopBroadcast();
    }
}
