// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {ModularAccountBase} from "../../src/account/ModularAccountBase.sol";
import {ExecutionLib} from "../../src/libraries/ExecutionLib.sol";
import {ModuleBase} from "../../src/modules/ModuleBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ExecutionManifest} from "@erc6900/reference-implementation/interfaces/IExecutionModule.sol";
import {
    Call, IModularAccount, ModuleEntity
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {HookConfigLib} from "@erc6900/reference-implementation/libraries/HookConfigLib.sol";
import {ModuleEntityLib} from "@erc6900/reference-implementation/libraries/ModuleEntityLib.sol";
import {ValidationConfigLib} from "@erc6900/reference-implementation/libraries/ValidationConfigLib.sol";
import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {console} from "forge-std/console.sol";

// Your module
import {SubscriptionLimitModule} from "../../src/modules/permissions/SubscriptionLimitModule.sol";

// Mocks & base harness (same pattern as native tests)
import {MockModule} from "../mocks/modules/MockModule.sol";
import {AccountTestBase} from "../utils/AccountTestBase.sol";

contract SubscriptionLimitModuleTest is AccountTestBase {
    address public merchant = makeAddr("merchant");
    MockERC20 public usdc;
    uint32 public validationEntityId = 1; // entity for the validator (SingleSigner/Mock)
    uint32 public hookEntityId = 42; // entity for THIS module's hooks (MUST match onInstall)
    uint64 private _nonce = 0;

    ExecutionManifest internal _m;
    MockModule public validationModule = new MockModule(_m);
    ModuleEntity public validationFunction;

    SubscriptionLimitModule public module = new SubscriptionLimitModule();

    // Cap: 15 USDC with 6 decimals (mocked via plain amounts)
    uint256 public cap = 15 * 1e6;
    uint48 public period = 30 days;
    uint48 public validUntil = uint48(block.timestamp + 365 days);
    bool public paused = false;

    function setUp() public override {
        _revertSnapshot = vm.snapshotState();

        // 1) Deploy token, mint to ACCOUNT so transfers can succeed (msg.sender = account)
        usdc = new MockERC20();
        usdc.mint(address(account1), 1_000_000 * 1e6);

        // Install validation entity and attach our module as both VALIDATION & EXECUTION hooks.
        // Validation hook install (read-only): use HookConfigLib.packValidationHook
        bytes[] memory hooks = new bytes[](2);
        hooks[0] = abi.encodePacked(
            HookConfigLib.packValidationHook({_module: address(module), _entityId: hookEntityId}),
            // onInstall data for our module: entityId, merchant, token, cap, period, validUntil, paused
            abi.encode(hookEntityId, merchant, address(usdc), cap, period, validUntil, paused)
        );

        // Execution hook install (write): use HookConfigLib.packExecHook
        hooks[1] = abi.encodePacked(
            HookConfigLib.packExecHook({
                _module: address(module),
                _entityId: hookEntityId,
                _hasPre: true,
                _hasPost: false
            }),
            // no additional init data required here; we already set terms in the previous step
            bytes("")
        );

        // Install validation on account1 with our mock validator + hooks
        vm.prank(address(account1));
        account1.installValidation(
            ValidationConfigLib.pack(address(validationModule), validationEntityId, true, true, true),
            new bytes4[](0),
            new bytes(0),
            hooks
        );

        validationFunction = ModuleEntityLib.pack(address(validationModule), validationEntityId);
    }

    // --- Helpers (similar to the native tests) ---

    function _encodeTransfer(address _token, address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("transfer(address,uint256)", _to, _amount);
    }

    // execute(target=token, value=0, data=transfer(merchant, amount))
    function _getExecuteTokenTransfer(address _token, address _merchant, uint256 _amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(ModularAccountBase.execute, (_token, 0, _encodeTransfer(_token, _merchant, _amount)));
    }

    function _getPackedUO(uint256 vgl, uint256 cgl, uint256 pvg, uint256 maxFee, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory uo)
    {
        uo = PackedUserOperation({
            sender: address(account1),
            nonce: _encodeNonce(ModuleEntityLib.pack(address(validationModule), validationEntityId), GLOBAL_V, _nonce),
            initCode: "",
            callData: abi.encodePacked(ModularAccountBase.executeUserOp.selector, callData),
            accountGasLimits: _encodeGas(VERIFICATION_GAS_LIMIT, CALL_GAS_LIMIT),
            preVerificationGas: pvg,
            gasFees: _encodeGas(1, 1),
            paymasterAndData: "",
            signature: _encodeSignature("") // no extra hook data passed
        });
    }

    // --- Tests ---

    // VALIDATION: within cap succeeds
    function test_validation_withinCap_pass() public withSMATest {
        vm.startPrank(address(entryPoint));
        uint256 amount = 10 * 1e6;
        // small gas; the module checks *token transfer* allowance, not gas usage
        uint256 result = account1.validateUserOp(
            _getPackedUO(100_000, 100_000, 100_000, 1, _getExecuteTokenTransfer(address(usdc), merchant, amount)),
            bytes32(0),
            0
        );
        // validationData: expect success (bit0 == 0) per 4337
        assertEq(result & 0x1, 0);
        vm.stopPrank();
    }

    // VALIDATION: over cap fails
    function test_validation_overCap_fail() public withSMATest {
        vm.startPrank(address(entryPoint));
        uint256 amount = 16 * 1e6; // cap is 15e6
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionLib.PreUserOpValidationHookReverted.selector,
                ModuleEntityLib.pack(address(module), hookEntityId),
                abi.encodeWithSelector(SubscriptionLimitModule.ExceedsCap.selector)
            )
        );
        account1.validateUserOp(
            _getPackedUO(100_000, 100_000, 100_000, 1, _getExecuteTokenTransfer(address(usdc), merchant, amount)),
            bytes32(0),
            0
        );
        vm.stopPrank();
    }

    // VALIDATION: wrong token fails
    function test_validation_wrongToken_fail() public withSMATest {
        vm.startPrank(address(entryPoint));
        address otherToken = makeAddr("otherToken");
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionLib.PreUserOpValidationHookReverted.selector,
                ModuleEntityLib.pack(address(module), hookEntityId),
                abi.encodeWithSelector(SubscriptionLimitModule.WrongToken.selector)
            )
        );
        account1.validateUserOp(
            _getPackedUO(100_000, 100_000, 100_000, 1, _getExecuteTokenTransfer(otherToken, merchant, 1e6)),
            bytes32(0),
            0
        );
        vm.stopPrank();
    }

    // VALIDATION: paused or expired
    function test_validation_paused_fail() public withSMATest {
        // Pause via account admin
        vm.prank(address(account1));
        module.setPaused(abi.encode(hookEntityId, merchant, true));

        vm.startPrank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionLib.PreUserOpValidationHookReverted.selector,
                ModuleEntityLib.pack(address(module), hookEntityId),
                abi.encodeWithSelector(SubscriptionLimitModule.PausedErr.selector)
            )
        );
        account1.validateUserOp(
            _getPackedUO(100_000, 100_000, 100_000, 1, _getExecuteTokenTransfer(address(usdc), merchant, 1e6)),
            bytes32(0),
            0
        );
        vm.stopPrank();
    }

    // VALIDATION: rollover simulated then pass
    function test_validation_rollover_simulated_pass() public withSMATest {
        // Spend close to cap in execution first (so validation later sees only a small remainder)
        _chargeExec(14 * 1e6);
        // Advance time past period so validation should simulate reset
        vm.warp(block.timestamp + period + 1);

        vm.startPrank(address(entryPoint));
        uint256 result = account1.validateUserOp(
            _getPackedUO(0, 0, 0, 0, _getExecuteTokenTransfer(address(usdc), merchant, 5 * 1e6)), bytes32(0), 0
        );
        assertEq(result & 0x1, 0);
        vm.stopPrank();
    }

    // EXECUTION: accounting increases spentInPeriod and enforces cap
    function test_execution_accounting_and_cap() public withSMATest {
        // First charge within cap
        _chargeExec(10 * 1e6);
        _nonce++;
        // Second charge within remaining (5e6)
        _chargeExec(5 * 1e6);
        _nonce++;

        // Expect any UserOperationRevertReason event (indicates failure)
        vm.expectEmit(false, false, false, false, address(entryPoint));
        emit IEntryPoint.UserOperationRevertReason(bytes32(0), address(0), 0, bytes(""));
        _chargeExec(1);
    }

    // EXECUTION: batch accounting (two transfers in one executeBatch)
    function test_execution_batch_accounting() public withSMATest {
        // Build two token transfers summing to 12e6
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(usdc), value: 0, data: _encodeTransfer(address(usdc), merchant, 7 * 1e6)});
        calls[1] = Call({target: address(usdc), value: 0, data: _encodeTransfer(address(usdc), merchant, 5 * 1e6)});

        vm.startPrank(address(entryPoint));
        PackedUserOperation[] memory uos = new PackedUserOperation[](1);
        uos[0] = _getPackedUO(0, 0, 0, 0, abi.encodeCall(IModularAccount.executeBatch, (calls)));
        entryPoint.handleOps(uos, beneficiary);
        vm.stopPrank();

        // After execution, spent should be 12e6; next 4e6 is allowed, over fails.
        _nonce++;
        _chargeExec(3 * 1e6);
        _nonce++;
        // Expect any UserOperationRevertReason event (indicates failure)
        vm.expectEmit(false, false, false, false, address(entryPoint));
        emit IEntryPoint.UserOperationRevertReason(bytes32(0), address(0), 0, bytes(""));
        _chargeExec(1);
    }

    // ADMIN: update cap & period and assert new limits apply
    function test_admin_update() public withSMATest {
        vm.prank(address(account1));
        module.update(abi.encode(hookEntityId, merchant, uint256(20 * 1e6), uint48(7 days), validUntil));
        // Now charging up to 20e6 in a 7-day window should succeed
        _chargeExec(20 * 1e6);
        // Next 1 wei should fail
        _nonce++;
        // Expect any UserOperationRevertReason event (indicates failure)
        vm.expectEmit(false, false, false, false, address(entryPoint));
        emit IEntryPoint.UserOperationRevertReason(bytes32(0), address(0), 0, bytes(""));
        _chargeExec(1);
    }

    function test_uninstall_removesLimitEnforcement() public withSMATest {
        // First, verify the limit is enforced before uninstall
        _chargeExec(15 * 1e6); // Spend full cap
        _nonce++;

        // Attempting to spend more should fail due to cap
        // Expect any UserOperationRevertReason event (indicates failure)
        vm.expectEmit(false, false, false, false, address(entryPoint));
        emit IEntryPoint.UserOperationRevertReason(bytes32(0), address(0), 0, bytes(""));
        _chargeExec(1); // Should fail

        // Call onUninstall directly from the account
        vm.prank(address(account1));
        module.onUninstall(abi.encode(hookEntityId, merchant));

        // Verify the module storage was cleared
        (
            address storedToken,
            address storedMerchant,
            uint256 maxPerPeriod,
            , //uint48 periodSecs,
            , //uint48 storedValidUntil,
            , //bool isPaused,
            , //uint256 spentInPeriod,
                //uint48 periodStart
        ) = module.limits(hookEntityId, address(account1), merchant);

        console.log("Stored Merchant:", storedMerchant);
        console.log("Stored Token:", storedToken);
        console.log("Max Per Period:", maxPerPeriod);

        assertEq(storedMerchant, address(0), "Merchant should be cleared after uninstall");
        assertEq(storedToken, address(0), "Token should be cleared after uninstall");
        assertEq(maxPerPeriod, 0, "Max per period should be cleared after uninstall");
    }

    /// @notice Test that spending cap resets after the period expires
    /// @dev After spending the full cap, advancing time past the period should allow spending again
    function test_execution_periodRollover_resetsSpending() public withSMATest {
        // Spend the full cap (15 USDC)
        _chargeExec(15 * 1e6);
        console.log("Successfully spent full cap");

        // Verify we're at the cap - next spend should fail
        uint256 balanceBefore = usdc.balanceOf(merchant);
        _nonce++;
        _chargeExec(1); // Should fail silently
        assertEq(usdc.balanceOf(merchant), balanceBefore, "Should not have transferred");
        console.log("Correctly failed on exceeding cap");

        // Advance time past the period (30 days + 1 second)
        vm.warp(block.timestamp + period + 1);

        // Now we should be able to spend the full cap again
        console.log("Trying to spend after rollover");
        _nonce++;

        // Expect Reset event right before the call that triggers it
        vm.expectEmit(true, true, true, true);
        emit SubscriptionLimitModule.Reset(hookEntityId, address(account1), merchant, uint48(block.timestamp));

        _chargeExec(15 * 1e6); // Should succeed and emit Reset
        console.log("Successfully spent after period rollover");

        // Verify we can't exceed cap in new period
        balanceBefore = usdc.balanceOf(merchant);
        _nonce++;
        _chargeExec(1); // Should fail - cap reached again
        assertEq(usdc.balanceOf(merchant), balanceBefore, "Should not have transferred after new cap reached");
    }

    // --- internal helper to execute a charge via EntryPoint (accounting happens in preExecutionHook) ---
    function _chargeExec(uint256 amount) internal {
        vm.startPrank(address(entryPoint));
        PackedUserOperation[] memory uos = new PackedUserOperation[](1);
        uos[0] = _getPackedUO(0, 0, 0, 0, _getExecuteTokenTransfer(address(usdc), merchant, amount));
        entryPoint.handleOps(uos, beneficiary);
        vm.stopPrank();
    }
}
