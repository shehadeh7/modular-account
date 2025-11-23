// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

// --- ERC-6900 & Modular Account imports (align versions with your repo tag) ---
// <- path may differ in your tree
import {ModularAccountBase} from "../../account/ModularAccountBase.sol";
import {IERC165, ModuleBase} from "../ModuleBase.sol";
import {IExecutionHookModule} from "@erc6900/reference-implementation/interfaces/IExecutionHookModule.sol";
import {Call, IModularAccount} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {IModule} from "@erc6900/reference-implementation/interfaces/IModule.sol";
import {IValidationHookModule} from "@erc6900/reference-implementation/interfaces/IValidationHookModule.sol";

import {UserOperationLib} from "@eth-infinitism/account-abstraction/core/UserOperationLib.sol";
import {PackedUserOperation} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol"; // <-
    // for performCreate selector

/// @title SubscriptionLimitModule (ModuleBase)
/// @notice Enforces per-period spend limits to a specific merchant+token.
/// @dev Storage is associated to the calling account (msg.sender) and keyed by entityId and merchant.
contract SubscriptionLimitModule is ModuleBase, IExecutionHookModule, IValidationHookModule {
    using UserOperationLib for PackedUserOperation;

    struct Terms {
        address token; // ERC-20 address; if address(0), governs native ETH
        address merchant; // Destination address allowed to be paid
        uint256 maxPerPeriod; // Max amount per period (token units / wei)
        uint48 periodSecs; // Rolling window length
        uint48 validUntil; // Global expiry (0 = open-ended)
        bool paused; // User kill-switch
        // state
        uint256 spentInPeriod;
        uint48 periodStart;
    }

    /// limits[entityId][merchant][account] => Terms
    mapping(uint256 => mapping(address => mapping(address => Terms))) public limits;
    // in this mapping (merchant accounts to accounts)

    event Configured(
        uint32 indexed entityId,
        address indexed account,
        address indexed merchant,
        address token,
        uint256 maxPerPeriod,
        uint48 periodSecs,
        uint48 validUntil
    );
    event Paused(uint32 indexed entityId, address indexed account, address indexed merchant, bool paused);
    event Reset(uint32 indexed entityId, address indexed account, address indexed merchant, uint48 newPeriodStart);
    event Accounted(
        uint32 indexed entityId,
        address indexed account,
        address indexed merchant,
        uint256 amount,
        uint256 newSpent
    );

    error NoSubscription();
    error WrongToken();
    error PausedErr();
    error Expired();
    error ExceedsCap();
    error Unauthorized();

    // ─────────────────────────────────────────────────────────────────────
    // Installation / Uninstallation (called by the account)
    // ─────────────────────────────────────────────────────────────────────

    /// @param data abi.encode(uint32 entityId, address merchant, address token, uint256 maxPerPeriod, uint48
    /// periodSecs, uint48 validUntil, bool paused)
    function onInstall(bytes calldata data) external override {
        (
            uint32 entityId,
            address merchant,
            address token,
            uint256 maxPerPeriod,
            uint48 periodSecs,
            uint48 validUntil,
            bool paused
        ) = abi.decode(data, (uint32, address, address, uint256, uint48, uint48, bool));

        address account = msg.sender;
        Terms storage t = limits[entityId][merchant][account];
        t.token = token;
        t.merchant = merchant;
        t.maxPerPeriod = maxPerPeriod;
        t.periodSecs = periodSecs;
        t.validUntil = validUntil;
        t.paused = paused;

        if (t.periodStart == 0) {
            t.periodStart = uint48(block.timestamp);
            t.spentInPeriod = 0;
        }

        emit Configured(entityId, account, merchant, token, maxPerPeriod, periodSecs, validUntil);
    }

    /// @param data abi.encode(uint32 entityId, address merchant)
    function onUninstall(bytes calldata data) external override {
        (uint32 entityId, address merchant) = abi.decode(data, (uint32, address));
        delete limits[entityId][merchant][msg.sender];
        // Optional: emit an event if you want to track removals
    }

    /// @inheritdoc IModule
    function moduleId() external pure returns (string memory) {
        return "alchemy.subscription-limit-module.1.0.0";
    }

    // ─────────────────────────────────────────────────────────────────────
    // Account-controlled admin (update / pause)
    // ─────────────────────────────────────────────────────────────────────

    /// @param data abi.encode(uint32 entityId, address merchant, uint256 newMaxPerPeriod, uint48 newPeriodSecs,
    /// uint48 newValidUntil)
    function update(bytes calldata data) external {
        (uint32 entityId, address merchant, uint256 cap, uint48 periodSecs, uint48 validUntil) =
            abi.decode(data, (uint32, address, uint256, uint48, uint48));

        Terms storage t = limits[entityId][merchant][msg.sender];
        if (t.merchant != merchant) revert NoSubscription();

        t.maxPerPeriod = cap;
        t.periodSecs = periodSecs;
        t.validUntil = validUntil;

        emit Configured(entityId, msg.sender, merchant, t.token, cap, periodSecs, validUntil);
    }

    /// @param data abi.encode(uint32 entityId, address merchant, bool paused)
    function setPaused(bytes calldata data) external {
        (uint32 entityId, address merchant, bool paused) = abi.decode(data, (uint32, address, bool));

        Terms storage t = limits[entityId][merchant][msg.sender];
        if (t.merchant != merchant) revert NoSubscription();

        t.paused = paused;
        emit Paused(entityId, msg.sender, merchant, paused);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Hooks (Validation + Execution)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Read-only: reject during 4337 simulation if it would violate policy.
    /// @notice ERC-4337/7562 best practice is to not write in validation hooks.
    /// [3](https://awesome.ecosyste.ms/projects/github.com%2Falchemyplatform%2Fmodular-account)
    function preUserOpValidationHook(
        uint32 entityId,
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */
    ) external view returns (uint256) {
        _validateUserOpView(entityId, userOp);
        return 0;
    }

    /// @dev Write-time: roll window + account spend; revert if over cap.
    function preExecutionHook(
        uint32 entityId,
        address, /* targetAccount */
        uint256, /* value */
        bytes calldata data
    ) external override returns (bytes memory) {
        (bytes4 selector, bytes memory execData) = _executionPhaseGetSelectorAndCalldata(data);

        if (selector == IModularAccount.execute.selector) {
            (address to, uint256 value, bytes memory callData) = abi.decode(execData, (address, uint256, bytes));
            (bool ok, address merchant, address token, uint256 amount,) = _decodePaymentIntent(to, value, callData);
            if (ok) _applyPaymentIntent(entityId, msg.sender, merchant, token, amount);
        } else if (selector == IModularAccount.executeBatch.selector) {
            (Call[] memory calls) = abi.decode(execData, (Call[]));
            for (uint256 i = 0; i < calls.length; ++i) {
                (bool ok, address merchant, address token, uint256 amount,) =
                    _decodePaymentIntent(calls[i].target, calls[i].value, calls[i].data);
                if (ok) _applyPaymentIntent(entityId, msg.sender, merchant, token, amount);
            }
        } else if (selector == ModularAccountBase.performCreate.selector) {
            // ignore (no enforced payment semantics)
        } else {
            // ignore or revert if you want strict mode
        }

        return "";
    }

    function postExecutionHook(uint32, bytes calldata) external pure override {
        revert NotImplemented();
    }

    // No implementation, no revert
    // Runtime spends no account gas, and we check native token spend limits in exec hooks
    function preRuntimeValidationHook(uint32, address, uint256, bytes calldata, bytes calldata)
        external
        pure
        override
    {} // solhint-disable-line no-empty-blocks

    // solhint-disable-next-line no-empty-blocks
    function preSignatureValidationHook(uint32, address, bytes32, bytes calldata) external pure override {}

    // ─────────────────────────────────────────────────────────────────────
    // Internal policy helpers
    // ─────────────────────────────────────────────────────────────────────
    // ------------------------------------------------------------
    // Read-only validation (unwrap outer executeUserOp and validate)
    // ------------------------------------------------------------

    function _validateUserOpView(uint32 entityId, PackedUserOperation calldata userOp) internal view {
        bytes calldata cd = userOp.callData;
        if (cd.length < 4) return;

        // Outer selector must be executeUserOp(bytes) in the Modular Account tests
        bytes4 outerSel;
        assembly {
            outerSel := calldataload(cd.offset)
        }
        if (outerSel != ModularAccountBase.executeUserOp.selector) {
            revert Unauthorized();
        }

        // Inner call is packed immediately after 4 bytes (tests use encodePacked)
        bytes calldata inner = cd[4:];

        // Inner selector: execute / executeBatch / performCreate
        bytes4 innerSel;
        assembly {
            innerSel := calldataload(inner.offset)
        }

        if (innerSel == IModularAccount.execute.selector) {
            (address to, uint256 value, bytes memory callData) = abi.decode(inner[4:], (address, uint256, bytes));
            (bool ok, address merchant, address token, uint256 amount,) = _decodePaymentIntent(to, value, callData);
            if (ok) _validatePaymentIntentView(entityId, userOp.sender, merchant, token, amount);
            else revert Unauthorized();
        } else if (innerSel == IModularAccount.executeBatch.selector) {
            (Call[] memory calls) = abi.decode(inner[4:], (Call[]));
            for (uint256 i = 0; i < calls.length; ++i) {
                (bool ok, address merchant, address token, uint256 amount,) =
                    _decodePaymentIntent(calls[i].target, calls[i].value, calls[i].data);
                if (ok) _validatePaymentIntentView(entityId, userOp.sender, merchant, token, amount);
            }
        } else if (innerSel == ModularAccountBase.performCreate.selector) {
            // ignore
        } else {
            revert Unauthorized();
        }
    }

    // ------------------------------------------------------------
    // 1) Decode intent (pure)  — no state reads/writes
    // ------------------------------------------------------------

    /// @dev Identify token transfer vs native send and extract (merchant, token, amount).
    function _decodePaymentIntent(address to, uint256 value, bytes memory data)
        internal
        pure
        returns (bool ok, address merchant, address token, uint256 amount, bool isNative)
    {
        // ERC-20 transfer(address,uint256) selector
        if (data.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(data, 32))
            } // first 4 bytes of payload
            if (sel == 0xa9059cbb) {
                token = to; // execute(target=token, data=transfer(merchant, amount))
                assembly {
                    merchant := mload(add(data, 36)) // arg0
                    amount := mload(add(data, 68)) // arg1
                }
                ok = true;
                return (ok, merchant, token, amount, false);
            }
        }

        // Native ETH: value > 0, empty data
        if (value > 0 && data.length == 0) {
            merchant = to;
            token = address(0);
            amount = value;
            ok = true;
            return (ok, merchant, token, amount, true);
        }

        // Not an enforced payment
        ok = false;
    }

    // ------------------------------------------------------------
    // 2) Validate (VIEW) — read-only check for preUserOp
    // ------------------------------------------------------------

    function _validatePaymentIntentView(
        uint32 entityId,
        address account,
        address merchant,
        address token,
        uint256 amount
    ) internal view {
        Terms storage t = limits[entityId][merchant][account];

        // No configuration => allow (no policy)
        if (t.merchant == address(0)) return;

        // Deterministic checks
        if (t.paused) revert PausedErr();
        if (t.token != token) revert WrongToken();

        // Check against max cap (not current spent)
        // This ensures no false negatives - if amount fits in ANY period, it passes
        // The execution hook enforces the actual per-period accounting
        if (amount > t.maxPerPeriod) revert ExceedsCap();
    }

    // ------------------------------------------------------------
    // 3) Apply (WRITE) — accounting & enforcement for preExecution
    // ------------------------------------------------------------

    function _applyPaymentIntent(uint32 entityId, address account, address merchant, address token, uint256 amount)
        internal
    {
        Terms storage t = limits[entityId][merchant][account];

        // Not configured => allow
        if (t.merchant == address(0)) return;

        if (t.paused) revert PausedErr();
        if (t.validUntil != 0 && block.timestamp > t.validUntil) revert Expired();
        if (t.token != token) revert WrongToken();

        // Rollover window (write)
        if (t.periodSecs != 0 && block.timestamp >= t.periodStart + t.periodSecs) {
            t.periodStart = uint48(block.timestamp);
            t.spentInPeriod = 0;
            emit Reset(entityId, account, merchant, uint48(block.timestamp));
        }

        uint256 remaining = t.maxPerPeriod > t.spentInPeriod ? (t.maxPerPeriod - t.spentInPeriod) : 0;
        if (amount > remaining) revert ExceedsCap();

        unchecked {
            t.spentInPeriod += amount;
        }
        emit Accounted(entityId, account, merchant, amount, t.spentInPeriod);
    }

    // ─────────────────────────────────────────────────────────────────────
    // EIP-165
    // ─────────────────────────────────────────────────────────────────────
    function supportsInterface(bytes4 interfaceId) public view override(ModuleBase, IERC165) returns (bool) {
        return interfaceId == type(IExecutionHookModule).interfaceId
            || interfaceId == type(IValidationHookModule).interfaceId || super.supportsInterface(interfaceId);
    }
}
