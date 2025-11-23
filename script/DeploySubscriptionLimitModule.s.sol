// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {Artifacts} from "./Artifacts.sol";
import {ScriptBase} from "./ScriptBase.sol";

// Deploys all standalone contracts.
// Modules:
// source .env file to set expected addresses and salts
// - SubscriptionLimitModule
contract DeploySubscriptionLimitModuleScript is ScriptBase, Artifacts {
    address public subscriptionLimitModuleAddr;
    uint256 public subscriptionLimitModuleSalt;

    function setUp() public {
        // Load the expected addresses and salts from env vars.
        subscriptionLimitModuleAddr = vm.envOr("SUBSCRIPTION_LIMIT_MODULE", address(0));
        subscriptionLimitModuleSalt = _getSaltOrZero("SUBSCRIPTION_LIMIT_MODULE");
    }

    function run() public {
        console.log("******** Deploying Modules *********");

        vm.startBroadcast();

        _safeDeploy(
            "Subscription Limit Module",
            subscriptionLimitModuleAddr,
            subscriptionLimitModuleSalt,
            _getSubscriptionLimitModuleInitcode(),
            _deploySubscriptionLimitModule
        );

        vm.stopBroadcast();
    }
}
