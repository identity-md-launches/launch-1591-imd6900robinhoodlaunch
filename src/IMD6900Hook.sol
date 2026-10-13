// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @notice IMD6900LockedPool: the one position this hook allows, the coin it pairs with ETH, and the pool's fee
interface ILockedPoolView {
    function token() external view returns (address);
    function upperTick() external view returns (int24);
    function fee() external view returns (uint24);
}

/// @notice The perps engine, once there is one: liquidates every position a trade would sink, before it runs
interface IPerpSweep {
    function sweepLiquidations(address liquidator, int256 spec, bool isBuy, uint160 limit) external returns (uint8);
    function openCount() external view returns (uint256);
}

/// @title IMD6900Hook - the ETH / IMD6900 pool's hook on Robinhood Chain: a locked pool, in-pool perps to come
/// @notice IMD6900RobinhoodLaunch creates it at an address that carries exactly its permissions. What it does:
///          - the pool is ETH / IMD6900 only, at a static fee, initialized by IMD6900LockedPool only: at the launch,
///            and again each time the timelock moves the liquidity to a pool with a lower fee (it serves the newest);
///          - liquidity comes from IMD6900LockedPool only, in its one range: nobody else can add a position;
///          - before any swap that is not the perps engine's own, the engine (once the Robinhood timelock wires one)
///            closes every position the trade would sink, at the price before it moves; a sweep that can't finish
///            reverts the trade (no bad debt outranks always-tradeable). Until an engine is set it does nothing.
///         No return deltas and no dynamic fee: the hook never touches a swap's amounts and charges nothing itself,
///         the pool's static fee is all there is, so Uniswap's router quotes the pool on its own.
contract IMD6900Hook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    int24 public constant TICK_SPACING = 60;
    /// @dev Gas kept back for the rest of the swap when a sweep runs, and the least worth forwarding
    uint256 internal constant SWEEP_GAS_RESERVE = 180_000;
    uint256 internal constant SWEEP_GAS_MIN = 400_000;

    /// @notice IMD6900LockedPool: initializes the pool and owns all of its liquidity
    address public immutable pool;

    /// @notice The perps engine; zero means spot only
    address public perpEngine;
    /// @notice Escape hatch: trade even when the pre-trade sweep can't run (meant only while an engine is replaced)
    bool public sweepFailOpen;
    /// @notice The wired engine takes its fees back (IMD6900LockedPool.feeCheckpoint / feeRefund around each swap):
    ///         then {perpFeeBps} reports only what can't come back. Off until the timelock says the engine does.
    bool public perpRefunded;
    /// @notice The pool this hook serves: the newest the locked pool initialized
    PoolId public poolId;

    event PerpEngineSet(address engine);
    event SweepFailOpenSet(bool on);
    event PerpRefundedSet(bool on);

    error NotOurPool();
    error OnlyPool();
    error WrongRange();
    /// @notice The pre-trade liquidation sweep ran out of gas: send the trade with more gas
    error SweepGasStarved();
    /// @notice The trade would sink more positions than one transaction can liquidate: trade smaller
    error SweepTradeTooLarge();
    /// @notice The perps engine could not run its sweep at all
    error SweepUnavailable();
    error NoRenounce();
    error EngineSet();

    /// @param owner_ the Robinhood timelock: the engine and the escape hatch wait out its delay
    constructor(IPoolManager poolManager_, address pool_, address owner_) BaseHook(poolManager_) {
        pool = pool_;
        _initializeOwner(owner_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The fee the perps engine's own swaps cost it, in basis points, rounded up (PerpEngine prices closes and
    ///         liquidations with it; without it, it assumes its 10% cap). The pool's static fee, unless the engine takes
    ///         it back ({perpRefunded}): then only Uniswap's protocol fee is left (none today).
    function perpFeeBps() public view returns (uint256) {
        if (!perpRefunded) return (uint256(ILockedPoolView(pool).fee()) + 99) / 100;
        (,, uint24 protocolFee,) = StateLibrary.getSlot0(poolManager, poolId);
        uint256 a = protocolFee & 0xfff;
        uint256 b = protocolFee >> 12;
        return ((a > b ? a : b) + 99) / 100;
    }

    /// @notice Who refunds the perps engine's fees: the locked pool, the owner of all the liquidity (the engine finds
    ///         it here, PerpSwapLib)
    function launcher() external view returns (address) {
        return pool;
    }

    /*                       OWNER (the Robinhood timelock)                  */

    /// @dev Replaceable: an engine whose sweep can never run blocks trading (fail closed), so the owner keeps the way
    ///      out, behind the timelock. Zero turns perps off.
    function setPerpEngine(address engine) external onlyOwner {
        perpEngine = engine;
        emit PerpEngineSet(engine);
    }

    /// @notice The perps engine the locked pool creates right after the launch (IMD6900LockedPool.createPerps), wired
    ///         at once and fee-free by refund. Only the locked pool, only while no engine is set: every later change
    ///         is the timelock's ({setPerpEngine}, {setPerpRefunded}).
    function initPerpEngine(address engine) external {
        if (msg.sender != pool) revert OnlyPool();
        if (perpEngine != address(0)) revert EngineSet();
        perpEngine = engine;
        perpRefunded = true;
        emit PerpEngineSet(engine);
        emit PerpRefundedSet(true);
    }

    /// @notice Set with the engine it describes: only an engine that calls the refund pair may be reported fee-free
    function setPerpRefunded(bool on) external onlyOwner {
        perpRefunded = on;
        emit PerpRefundedSet(on);
    }

    function setSweepFailOpen(bool on) external onlyOwner {
        sweepFailOpen = on;
        emit SweepFailOpenSet(on);
    }

    /// @notice Ownership never goes to nobody: the engine and the escape hatch need an owner
    function renounceOwnership() public payable override onlyOwner {
        revert NoRenounce();
    }

    /*                              CALLBACKS                               */

    /// @dev Only the locked pool, only ETH / its coin at the locked pool's current static fee, tick spacing 60, this
    ///      hook. The locked pool initializes once at the launch, then once per lower fee it moves to; the newest is
    ///      the one served.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != pool) revert OnlyPool();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != ILockedPoolView(pool).token()
                || LPFeeLibrary.isDynamicFee(key.fee) || key.fee != ILockedPoolView(pool).fee()
                || key.tickSpacing != TICK_SPACING
        ) revert NotOurPool();
        poolId = key.toId();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _checkLiquidity(sender, params);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev The locked pool takes liquidity out only to put it straight into its next, cheaper pool (in the same
    ///      unlock), and otherwise only collects its fees (a zero change, which v4 routes here)
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _checkLiquidity(sender, params);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert NotOurPool();
        _sweep(sender, params.amountSpecified, params.zeroForOne, params.sqrtPriceLimitX96);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev A second, best-effort sweep for anything the final price leaves under water
    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _sweep(sender, 0, false, 0);
        return (BaseHook.afterSwap.selector, int128(0));
    }

    /*                               INTERNAL                               */

    function _checkLiquidity(address sender, ModifyLiquidityParams calldata params) internal view {
        if (sender != pool) revert OnlyPool();
        if (
            params.tickLower != TickMath.minUsableTick(TICK_SPACING)
                || params.tickUpper != ILockedPoolView(pool).upperTick()
        ) revert WrongRange();
    }

    /// @dev The liquidation sweep for both callbacks. `spec != 0` is the pre-trade sweep and fails closed; the
    ///      post-trade one (`spec == 0`) is best-effort. The engine's own swaps skip it: they are the sweep. The EOA
    ///      that sent the transaction is the liquidator and takes the keeper's cut.
    function _sweep(address sender, int256 spec, bool isBuy, uint160 limit) internal {
        address engine = perpEngine;
        if (engine == address(0) || sender == engine) return;
        uint256 reserve = spec != 0 ? SWEEP_GAS_RESERVE + SWEEP_GAS_MIN : SWEEP_GAS_RESERVE;
        uint256 g = gasleft();
        if (g > reserve + SWEEP_GAS_MIN) {
            (bool ok, bytes memory out) =
                engine.call{gas: g - reserve}(abi.encodeCall(IPerpSweep.sweepLiquidations, (tx.origin, spec, isBuy, limit)));
            if (spec == 0) return;
            if (!ok || out.length < 32) {
                if (!sweepFailOpen) revert SweepUnavailable();
                return;
            }
            uint256 status = abi.decode(out, (uint256));
            if (status == 2) revert SweepTradeTooLarge();
            if (status != 0) revert SweepGasStarved();
        } else if (spec != 0) {
            // too little gas to sweep: refuse the trade while positions are open, rather than trade blind; an engine
            // that can't even say whether positions are open fails closed here too (unless fail-open is set)
            (bool ok, bytes memory ret) = engine.staticcall(abi.encodeCall(IPerpSweep.openCount, ()));
            if (!ok || ret.length < 32) {
                if (!sweepFailOpen) revert SweepUnavailable();
            } else if (abi.decode(ret, (uint256)) != 0) {
                revert SweepGasStarved();
            }
        }
    }
}
