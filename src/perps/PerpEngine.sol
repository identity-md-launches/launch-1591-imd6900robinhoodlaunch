// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PerpSwapLib, Position} from "./PerpSwapLib.sol";

/// @dev v4's unlock callback (the vendored v4-core subset in lib/ does not ship the interface file)
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Just enough of {PerpVault} to ask whether anyone still has value in it.
interface IPerpVaultStake {
    function hasStakers() external view returns (bool);
}

/// @dev The pool hook's fee on this engine's own swaps (the IMD6900 Robinhood hook). Read defensively.
interface IPerpFeeView {
    function perpFeeBps() external view returns (uint256);
}

/// @dev The hook names the engine it sweeps for; opens wait until that is this one.
interface IPerpHookView {
    function perpEngine() external view returns (address);
}

/// @dev Where the non-vault share of perp fees goes (the IMD6900 launcher on Robinhood: machine pot + $IMD).
interface IPerpFeeSink {
    function addPerpFees() external payable;
}

/**
 * @title PerpEngine (IMD6900 on Robinhood Chain)
 * @notice Real-swap leverage on the IMD6900 ETH pool, ported from MiFrens Cauldron's audited PerpEngine with
 *         everything Cauldron-specific removed: no registry or generations (one token, one pool, forever), no
 *         death / relaunch / quote rotation, no Liquidatoor badges, no MiFrens discount, native ETH only.
 *
 *  - LONG: borrows ETH from the PLV to buy the token (price up). Closes by selling.
 *  - SHORT: borrows TOKEN from the PLV's token inventory, sells it (price down), holds the ETH. Closes by buying
 *    the token back (price up) and returning it to the inventory.
 *
 *  FEES: 6.9% of the deposited collateral at open (owner-editable, capped at 10%), split by default 20% LP yield
 *  (the stakers), 10% insurance, 70% to the fee sink (the launch, which sends it all as ETH to the NFT floor pot);
 *  the liquidation penalty the same way, after the keeper's cut. The split is the owner's to change ({setVaultSplit}). Every open, close and liquidation is also a real swap
 *  through the pool and pays the hook's perp rate on it (1% by default, never more than 10%), not the 10% spot fee.
 *
 *  NO BAD DEBT, BY CONSTRUCTION. A position is liquidated while closing it still repays its debt: the trigger
 *  prices the close itself (constant-product impact at the active depth, the hook's fee on top) as if the whole
 *  of its side, at least its open-interest cap, were being liquidated in front of it, so any order a cascade
 *  settles in stays solvent. Every price move in this pool is a swap through the hook, whose pre-trade sweep
 *  closes what the trade would sink at the price BEFORE the trade, so the trigger is never crossed by a jump.
 *  An open that would already trip is refused.
 *
 *  RISK LIMITS: owner-set leverage (2x minimum, no 1x, so perps are never a cheaper spot route; 5x default,
 *  independent of pool depth); per-position notional and per-side OI capped to shares of active depth; long OI
 *  <= PLV ETH, short OI <= PLV token, so the vault can never lend what it does not hold. A funding index charges
 *  the crowded side. Liquidations run keeperless inside every pool swap ({sweepLiquidations}, called by the hook),
 *  on the WORSE of a TWAP mark (with maintenance buffer) and spot/projected insolvency (no buffer).
 *
 *  Audit fixes carried over from Cauldron are cited by their IDs (A-02, F-10, M-01, H-04, L-05, LIQ-01, LIQ-02,
 *  LIQ04, H1, H1B, R1B, L-2, E1A, V-01, A-04, I1, M-05, H-01, R-09, Z-02, G-0x).
 */
contract PerpEngine is IUnlockCallback, Ownable, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── wiring (immutable) ──
    IPoolManager public immutable poolManager;
    address public immutable hookAddr;
    /// @notice The IMD6900 token (currency1; native ETH is currency0 and the quote)
    address public immutable token;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    PoolId public immutable poolId;

    // ── constants ──
    uint256 internal constant BPS = 10_000;
    uint8 internal constant MODE_NORMAL = 0;
    uint8 internal constant MODE_LIQUIDATION = 1;
    /// @notice No 1x: a fully collateralised long is just a spot buy at the lower perp fee
    uint8 public constant MIN_LEVERAGE = 2;
    /// @notice Hard ceiling for {setRisk}
    uint8 public constant MAX_LEVERAGE_CAP = 10;
    /// @notice Hard ceiling for the engine's own open fee
    uint256 public constant MAX_OPEN_FEE_BPS = 1_000;
    /// @dev The hook's fee on this engine's swaps never exceeds this (it is hard-capped there too). It is assumed
    ///      whenever the hook cannot answer {IPerpFeeView.perpFeeBps}, and a bounded exact-output buy-back, which
    ///      pays the fee ON TOP of what the pool takes, sizes its pool leg net of it ({_buyUpTo}).
    uint256 internal constant HOOK_FEE_CAP_BPS = 1_000;

    // ── config (owner-tunable) ──
    /// @notice Receives the non-vault share of every routed fee, pulled by {flushFees}
    address public feeSink;
    /// @notice Open fee, in bps of the deposited collateral
    uint256 public openFeeBps = 690;
    uint256 public liqPenaltyBps = 690;
    /// @notice Liquidator's cut of the penalty (145 bps of the 6.9% penalty is about 0.1% of collateral)
    uint256 public keeperBps = 145;
    /// @notice Highest leverage a new position may take, independent of pool depth
    uint8 public maxLeverage = 5;
    /// @notice Liquidation buffer on the TWAP mark. 10% rather than Cauldron's 15%: at 5x a short's backing is
    ///         only ~1.19x its notional, so 15% leaves it ~1% from liquidation the moment it opens.
    uint256 public maintenanceBps = 1_000;
    /// @notice Per-position notional <= 3.5% of active ETH depth: room for a 5x of the minimum collateral in the
    ///         migrated pool (1.70 ETH of depth)
    uint256 public maxNotionalBps = 350;
    /// @notice Long side: total notional <= 5% of active ETH depth. Also the longs' liquidation RESERVE: every long
    ///         keeps enough margin to be closed with this much of its side closing in front of it. Raising it adds
    ///         capacity but makes every long liquidate sooner; it can never create bad debt.
    uint256 public maxOiBps = 500;
    /// @notice Short side: total owed <= 10% of the pool's token depth, and the shorts' reserve, likewise. With the 1%
    ///         pool fee and 10% maintenance a 10% reserve leaves a 2x short ~20% of room, 3x ~8%, 4x ~2%, and refuses
    ///         5x at open; past ~16% no short can open at all. Bad debt stays impossible at any setting.
    uint256 public maxShortOiBps = 1_000;
    /// @notice Minimum collateral (after the open fee) to open a position. Fewer, larger positions keep the book the
    ///         liquidation sweep scans on every swap small, so every trade stays cheap. 0 = no floor.
    uint256 public minCollateral = 0.01 ether;

    /// @notice Hard cap on how many positions one swap's sweep may liquidate: the physical ceiling under
    ///         EIP-7825 (16,777,216 gas a transaction, ~440k a kill) with margin. Past it the trade must be smaller.
    uint256 internal constant MAX_LIQ_PER_SWAP = 30;
    //  Sweep outcomes, ordered by what the caller can do about them.
    uint8 internal constant SWEEP_OK        = 0; // book fully scanned, nothing owed
    uint8 internal constant SWEEP_GAS       = 1; // ran out of gas -- RETRY WITH MORE
    uint8 internal constant SWEEP_TOO_LARGE = 2; // more condemned than any tx can close
    /// @dev How many times the sweep may re-read the book to chase its own settlement impact.
    uint256 internal constant MAX_CASCADE_PASSES = 4;
    /// @notice Hard cap on live positions, which is what bounds the sweep's scan.
    uint256 public constant MAX_OPEN_POSITIONS = 64;

    // ── Community PLV (LP-for-perps) ──
    /// @notice The PerpVault that supplies depositor liquidity. Zero = owner-seeded only.
    address public vault;
    /// @notice ETH bad-debt buffer, drawn before depositor principal.
    uint256 public insuranceEth;
    /// @notice Of every routed fee: this share is LP yield (side-attributed), `insuranceBps` funds the buffer,
    ///         the rest goes to the fee sink. Defaults 20 / 10 / 70 (owner-editable: {setVaultSplit}).
    uint256 public vaultYieldBps = 2_000;
    uint256 public insuranceBps = 1_000;
    /// @notice Max share of each side's vault assets lent to traders; the rest is always withdrawable.
    uint256 public maxUtilBps = 8_000;
    /// @notice Opens pause while insurance sits below max(this, maintenance on open interest). 0 = risk-based only.
    uint256 public insuranceFloor;
    /// @notice Funding rate at 100% imbalance, charged to the crowded side per second, accruing to the PLV.
    uint256 public fundingRateBpsPerDay = 100;

    // ── hardening knobs (owner-tunable) ──
    /// @notice Liquidation-mark averaging window. 2s: on Robinhood's sub-second blocks that already spans many
    ///         blocks; the spot/projected insolvency leg covers the crash case either way.
    uint32 public twapWindow = 2 seconds;
    /// @notice ETH notional liquidated per timestamp <= 20% of depth (insolvent positions exempt)
    uint256 public maxLiqBps = 2_000;
    /// @notice |funding P&L| <= 50% of collateral
    uint256 public maxFundingBps = 5_000;

    // ── TWAP oracle: a ring of cumulative-tick observations (Uniswap-style) ──
    //  Appends are TIME-throttled (>= OBS_INTERVAL apart), so the ring cannot be flooded to evict history.
    uint16 internal constant OBS_CARDINALITY = 32;
    uint32 internal constant OBS_INTERVAL = 15 seconds;
    uint32 internal constant MIN_TWAP = 1 seconds;
    PerpSwapLib.Observation[OBS_CARDINALITY] internal observations;
    PerpSwapLib.Ring internal ring;

    // ── per-timestamp liquidation throttle ──
    //  Keyed on block.timestamp, not block.number: on Arbitrum Orbit chains block.number is the L1 number.
    uint256 internal liqBlock;
    uint256 internal liqEthThisBlock;

    // ── hook-driven (in-swap) liquidation ──
    //  `_inLocked`: already inside the PoolManager lock (the hook called us), so swap directly.
    //  `_liqReentry`: a sweep is running; blocks nesting and every user entrypoint (M-01).
    bool internal _inLocked;
    bool internal _liqReentry;
    /// @dev Non-zero only during a pre-emptive sweep: the price the pending swap is projected to leave behind.
    uint160 internal _projSqrtP;

    // ── Perp Liquidity Vault (two-sided) ──
    uint256 public plv;         // ETH available to front long borrows
    uint256 public plvToken;    // token available to lend to shorts
    /// @notice ETH reward pot for the TOKEN side (short-attributed fees), kept out of `plv`.
    uint256 public tokYieldEth;
    /// @notice Lifetime ETH routed to the token side (monotonic); the vault folds deltas of it.
    uint256 public tokYieldCumulative;
    /// @notice ETH owed to `feeSink`, paid out by {flushFees}
    uint256 public feesOwed;

    // ── funding index (1e18-scaled); + means longs pay, - means shorts pay ──
    int256 internal fundingIndex;
    uint64 internal lastFundingAt;

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;
    uint256 public openCount;

    /// @notice ETH a settlement could not push to a trader/keeper (their `receive()` reverted); claimed via
    ///         {claimPayout}. Stops one hostile trader from freezing every settlement path (H-04).
    mapping(address => uint256) public payoutOwed;
    uint256 public payoutOwedTotal;
    /// @notice Realised loss that exceeded BOTH insurance and the whole PLV. A monotonic ledger, never a balance:
    ///         never gate on it (I1).
    uint256 public unabsorbedEth;

    // ── enumerable open set: lets ANY swap scan and liquidate without a hint. O(1) add/remove. ──
    uint256[] internal _openIds;
    mapping(uint256 => uint256) internal _openPos; // id -> 1-based index in _openIds
    uint256 internal sweepCursor;
    /// @dev Gas one in-swap liquidation needs to finish (~388k measured, rounded up) (L-2).
    uint256 internal constant SWEEP_KILL_RESERVE = 420_000;
    uint256 public longOiEth;    // sum of ETH borrowed by open longs
    uint256 public longSizeToken; // sum of token held by open longs (their notional, priced live)
    uint256 public shortOiToken; // sum of token owed by open shorts

    error BadLeverage();
    error PlvInsufficient();
    error OiCapped();
    error NotTrader();
    error NotOpen();
    error Healthy();
    error Slippage();
    error EthSend();
    error ZeroValue();
    error LiqCapped();
    error OnlyHook();
    error Reentrant();
    error NotVault();
    error UtilCapped();
    error InsurancePaused();
    error DustPosition();
    error BadParam();
    error OwnershipCannotBeRenounced();
    /// @notice The position would be liquidatable the moment it opened
    error WouldLiquidate();
    /// @notice The hook doesn't sweep for this engine (not wired yet, or replaced): no pre-emptive liquidation, no opens
    error PerpsOff();

    event Opened(uint256 indexed id, address indexed trader, bool isLong, uint256 collateral, uint256 size, uint8 leverage);
    event Closed(uint256 indexed id, address indexed trader, uint256 payout, int256 pnl);
    event Liquidated(uint256 indexed id, address indexed keeper, uint256 penalty);
    /// @notice A close/liquidation could only unwind PART of a short; `remaining` stays open under the same id and
    ///         is re-liquidatable at once. Fires INSTEAD of {Closed} (LIQ-02).
    event PartiallyClosed(uint256 indexed id, uint256 bought, uint256 cost, uint256 remaining);
    /// @notice A long's sale left `amount` token unsold; the engine keeps it as LP inventory.
    event TokenDebtWrittenOff(uint256 indexed id, uint256 amount);
    event FeeRouted(uint256 toVault, uint256 toInsurance, uint256 toSink);
    event FeesFlushed(address indexed sink, uint256 amount);
    event PlvFunded(uint256 eth, uint256 token);
    event BadDebt(uint256 shortfall, uint256 covered);
    event BadDebtUnabsorbed(uint256 amount, uint256 total);
    event PayoutOwed(address indexed to, uint256 amount);
    event VaultFunded(bool isEth, uint256 amount);
    event VaultWithdrawn(bool isEth, uint256 amount, address to);

    constructor(
        IPoolManager _poolManager,
        address _hook,
        address _token,
        uint24 _poolFee,
        int24 _tickSpacing,
        address _feeSink,
        address _owner
    ) Ownable(_owner) {
        if (_token == address(0) || _hook == address(0)) revert BadParam();
        poolManager = _poolManager;
        hookAddr = _hook;
        token = _token;
        poolFee = _poolFee;
        tickSpacing = _tickSpacing;
        poolId = PoolKey(Currency.wrap(address(0)), Currency.wrap(_token), _poolFee, _tickSpacing, IHooks(_hook)).toId();
        feeSink = _feeSink;
        lastFundingAt = uint64(block.timestamp);
        // The pool must already trade: the TWAP oracle seeds from its live tick, and an uninitialized pool reads 0.
        if (_sqrtP() == 0) revert BadParam();
        // Seed the TWAP oracle with the live tick so the mark is meaningful from block one.
        ring.lastObsTs = uint32(block.timestamp);
        ring.lastRingTs = uint32(block.timestamp);
        ring.lastTick = _tick();
        observations[0] = PerpSwapLib.Observation(uint32(block.timestamp), 0);
        ring.obsIndex = 1;
    }

    /// @notice Ownership cannot be renounced: every risk lever lives behind it. Hand it to the timelock instead.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @dev Block re-entry into any user entrypoint while an in-swap liquidation is settling (M-01).
    modifier notNested() { _notNested(); _; }
    modifier onlyVault() { _onlyVault(); _; }
    function _notNested() internal view { if (_inLocked || _liqReentry) revert Reentrant(); }
    function _onlyVault() internal view { if (msg.sender != vault) revert NotVault(); }

    // ── Community PLV views (the PerpVault prices shares off these) ──
    /// @notice ETH the ETH side owns: free + lent to open longs. Insurance is NOT LP equity.
    function totalEth() public view returns (uint256) { return plv + longOiEth; }
    function freeEth() external view returns (uint256) { return plv; }
    /// @notice Token the token side owns: free inventory + lent to shorts.
    function totalTokenAssets() public view returns (uint256) { return plvToken + shortOiToken; }
    function freeToken() external view returns (uint256) { return plvToken; }
    /// @notice Live position ids (<= MAX_OPEN_POSITIONS)
    function openIds() external view returns (uint256[] memory) { return _openIds; }

    // ── pool + price ──
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), poolFee, tickSpacing, IHooks(hookAddr));
    }
    function _liq() internal view returns (uint128) { return poolManager.getLiquidity(poolId); }
    function _slot0() internal view returns (uint160 s, int24 t) { (s, t,,) = poolManager.getSlot0(poolId); }
    function _sqrtP() internal view returns (uint160 s) { (s, ) = _slot0(); }
    function _tick() internal view returns (int24 t) { (, t) = _slot0(); }

    // ── TWAP oracle ──
    /// @notice Record a TWAP observation and accrue funding. Open to keepers so the mark and funding stay current.
    function poke() external { _pokeFunding(); }

    /// @dev Sample the oracle. ALWAYS integrates the elapsed interval and refreshes `ring.lastTick`, so a stale tick
    ///      can never be extrapolated over the window (A-02); ring appends stay throttled on their own clock.
    ///      Timestamp deltas are unchecked, uint32 wrap safe (F-10).
    function _writeObs() internal {
        PerpSwapLib.writeObs(observations, ring, OBS_INTERVAL, _tick());
    }

    /// @notice Time-weighted average tick for the liquidation mark. Prefers a lookback >= `twapWindow`, else the
    ///         oldest observation if it spans >= MIN_TWAP; `ok=false` only at genuine cold start.
    function twapTick() public view returns (int24 tick, bool ok) {
        return PerpSwapLib.twapTick(observations, ring, twapWindow);
    }

    /// @notice The manipulation-resistant mark sqrtPrice (TWAP tick; spot fallback).
    function markSqrtPriceX96() public view returns (uint160) {
        (int24 t, bool ok) = twapTick();
        return ok ? PerpSwapLib.sqrtPriceAtTick(t) : _sqrtP();
    }

    /// @notice Active ETH depth of the pool at the current price
    function activeEthDepth() public view returns (uint256) {
        uint160 sp = _sqrtP();
        if (sp == 0) return 0;
        return PerpSwapLib.ethDepth(_liq(), sp);
    }

    /// @dev token -> ETH value at sqrtPrice sp. Pool price p = (sp/Q96)^2 = token/ETH, so value = size*(Q96/sp)^2.
    function _quoteAt(uint256 size, uint256 sp) internal view returns (uint256) {
        return PerpSwapLib.quoteAt(size, sp);
    }
    /// @dev token -> ETH at SPOT
    function _quoteEth(uint256 size) internal view returns (uint256) { return _quoteAt(size, _sqrtP()); }
    /// @dev token -> ETH at the TWAP MARK
    function _quoteMark(uint256 size) internal view returns (uint256) { return _quoteAt(size, markSqrtPriceX96()); }
    /// @dev ETH -> token amount at spot
    function _ethToToken(uint256 eth) internal view returns (uint256) {
        return PerpSwapLib.ethToToken(eth, _sqrtP());
    }

    // ── funding: accrue the global index by imbalance x elapsed ──
    function _pokeFunding() internal {
        _writeObs(); // sample the pre-trade tick for the TWAP mark
        uint256 dt = block.timestamp - lastFundingAt;
        if (dt == 0) return;
        lastFundingAt = uint64(block.timestamp);
        // Short OI valued at the MARK, not spot (L-05).
        uint256 shortEth = _quoteMark(shortOiToken);
        uint256 total = longOiEth + shortEth;
        if (total == 0) return;
        int256 imbalance = int256(longOiEth) - int256(shortEth);
        int256 step = (imbalance * int256(fundingRateBpsPerDay) * int256(dt) * 1e18)
            / (int256(total) * int256(BPS) * int256(1 days));
        fundingIndex += step;
    }

    /// @dev Signed funding P&L since open. Positive = crowded side, PAYS; negative = RECEIVES. Notional pinned to
    ///      entry so it cannot be gamed by moving spot; bounded to +-maxFundingBps of collateral.
    function _fundingDelta(Position memory p) internal view returns (int256) {
        int256 diff = fundingIndex - p.entryFunding;
        int256 signed = p.isLong ? diff : -diff;
        uint256 notional = uint256(p.collateral) * p.leverage;
        int256 raw = (signed * int256(notional)) / 1e18;
        int256 cap = int256((uint256(p.collateral) * maxFundingBps) / BPS);
        if (raw > cap) raw = cap;
        if (raw < -cap) raw = -cap;
        return raw;
    }

    function _pos(uint256 id) internal view returns (Position memory) { return positions[id]; }

    /// @notice Signed funding P&L for a live position
    function fundingDelta(uint256 id) external view returns (int256) {
        Position memory p = _pos(id);
        if (p.trader == address(0)) return 0;
        return _fundingDelta(p);
    }

    // ---------------------------------------------------------------------
    // Open
    // ---------------------------------------------------------------------
    struct SwapReq { bool buy; bool exactOut; uint256 amount; uint160 limit; }

    /// @notice Open a long with `msg.value` as collateral. The post-open sweep liquidates whatever is underwater,
    ///         best-effort, and can never revert the open.
    function openLong(uint8 leverage, uint256 minTokenOut)
        external payable nonReentrant notNested returns (uint256 id)
    {
        _openPrologue(leverage);

        uint256 collateral = _takeFee(msg.value, true);
        if (collateral < minCollateral) revert DustPosition();
        uint256 borrow = collateral * (leverage - 1);
        if (borrow > plv) revert PlvInsufficient();
        _utilGate(longOiEth + borrow, totalEth());
        uint256 buyEth = collateral + borrow;
        _checkNotional(buyEth);
        // Side cap on NOTIONAL (what a liquidation has to sell), not on the borrowed part.
        if (_quoteEth(longSizeToken) + buyEth > (activeEthDepth() * maxOiBps) / BPS) revert OiCapped();

        plv -= borrow; longOiEth += borrow;
        (, uint256 sizeOut) = _swapExactIn(true, buyEth, 0); // ETH -> token (price UP)
        if (sizeOut < minTokenOut) revert Slippage();
        longSizeToken += sizeOut;

        id = _book(msg.sender, true, collateral, sizeOut, borrow, leverage);
        _refuseBornLiquidatable(id);
        _sweepAfterOpen(msg.sender);
    }

    /// @notice Open a short with `msg.value` as collateral.
    function openShort(uint8 leverage, uint256 minEthOut)
        external payable nonReentrant notNested returns (uint256 id)
    {
        _openPrologue(leverage);

        uint256 collateral = _takeFee(msg.value, false);
        if (collateral < minCollateral) revert DustPosition();
        // Notional (in ETH) = collateral x leverage; borrow that much TOKEN value.
        uint256 notionalEth = collateral * leverage;
        _checkNotional(notionalEth);
        uint256 tokenToSell = _ethToToken(notionalEth);
        if (tokenToSell > plvToken) revert PlvInsufficient();
        _utilGate(shortOiToken + tokenToSell, totalTokenAssets());
        if (shortOiToken + tokenToSell > (_ethToToken(activeEthDepth()) * maxShortOiBps) / BPS) revert OiCapped();

        plvToken -= tokenToSell; shortOiToken += tokenToSell;
        (, uint256 proceeds) = _swapExactIn(false, tokenToSell, 0); // sell borrowed token (price DOWN)
        if (proceeds < minEthOut) revert Slippage();

        // The engine holds collateral + proceeds ETH as backing for the token debt.
        id = _book(msg.sender, false, collateral, tokenToSell, proceeds, leverage);
        _refuseBornLiquidatable(id);
        _sweepAfterOpen(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Close / liquidate
    // ---------------------------------------------------------------------
    function close(uint256 id, uint256 minOut) external nonReentrant notNested {
        Position memory p = _pos(id);
        if (p.trader != msg.sender) revert NotTrader();
        _pokeFunding();
        _settle(id, p, minOut, MODE_NORMAL, address(0));
    }

    /// @notice Permissionless liquidation. Off the in-swap sweep the spot leg of {_liqTest} reads raw live spot,
    ///         which the caller may have just moved; that is closed at SETTLEMENT by the mark band on a short's
    ///         buy-back (E1A), not here, because spot-only liquidatability is load-bearing for real crashes.
    function liquidate(uint256 id) external nonReentrant notNested {
        Position memory p = _pos(id);
        if (p.trader == address(0)) revert NotOpen();
        _pokeFunding();
        (bool trip, bool insolvent, uint256 notional) = _liqTest(p);
        if (!trip) revert Healthy();
        if (!_throttle(insolvent, notional)) revert LiqCapped();
        _settle(id, p, 0, MODE_LIQUIDATION, msg.sender);
    }

    /// @notice HINT-FREE auto-liquidation for ANY swap on ANY interface. The hook calls this from beforeSwap (with
    ///         the pending trade's `spec`, so a trade cannot sink a position and escape its liquidation) and from
    ///         afterSwap (`spec == 0`). Hook-only.
    /// @param spec  v4's signed amount for the PENDING swap (negative = exact input), or 0 post-trade
    /// @param isBuy true when ETH is the input (token gets dearer)
    /// @param limit the swap's own sqrtPriceLimitX96; the projection may not pass it
    /// @return status SWEEP_OK / SWEEP_GAS (retry with more gas) / SWEEP_TOO_LARGE (trade smaller). The hook turns
    ///         a non-OK PRE-trade status into a revert (H1).
    function sweepLiquidations(address liquidator, int256 spec, bool isBuy, uint160 limit)
        external
        returns (uint8 status)
    {
        if (msg.sender != hookAddr) revert OnlyHook();
        status = _doSweep(liquidator, true, spec, isBuy, limit);
    }

    /// @dev The pending trade's projected post-swap price from CURRENT spot (constant product over active depth).
    function _project(int256 spec, bool isBuy, uint160 limit) internal view returns (uint160) {
        uint256 eDepth = activeEthDepth();
        uint256 tDepth = _ethToToken(eDepth);
        return PerpSwapLib.projectedSqrtPriceX96(
            _sqrtP(), isBuy ? eDepth : tDepth, isBuy ? tDepth : eDepth, spec, isBuy, limit
        );
    }

    /// @dev Post-open sweep entrypoint: the engine calls it ON ITSELF so it can be wrapped in try/catch.
    function selfSweep(address liquidator) external {
        if (msg.sender != address(this)) revert OnlyHook();
        _doSweep(liquidator, false, int256(0), false, 0);
    }

    /// @dev Fire the post-open sweep best-effort, keeping a reserve so it can never revert the open.
    function _sweepAfterOpen(address liquidator) internal {
        uint256 g = gasleft();
        if (g <= 250_000) return;
        uint256 fwd = g - 120_000;
        try this.selfSweep{gas: fwd}(liquidator) {} catch {}
    }

    /// @dev Bounded sweep over the whole (<= 64) book. `inLocked` = already inside the PoolManager lock (hook path).
    function _doSweep(address liquidator, bool inLocked, int256 spec, bool isBuy, uint160 limit)
        internal
        returns (uint8 status)
    {
        status = SWEEP_OK;
        if (_liqReentry) return status;
        // Sample the oracle FIRST, always, even on an empty book (Z-02).
        _pokeFunding();
        uint256 len = _openIds.length;
        if (len == 0) return status;
        // Pre-trade membership must survive swap-pop and partial rebooking.
        uint256[] memory pendingIds;
        if (spec != 0) pendingIds = _openIds;
        _liqReentry = true;
        _inLocked = inLocked;
        uint256 cursor = sweepCursor;
        uint256 scanned;
        uint256 kills;
        //  The whole book is the window and gas is the bound (R1B): a positional window can be aimed. Once the kill
        //  cap is reached a PRE-trade sweep keeps walking CHECK-ONLY and reports SWEEP_TOO_LARGE the moment it finds
        //  another position the pending trade condemns (H1B).
        while (scanned < len && (kills < MAX_LIQ_PER_SWAP || spec != 0)) {
            // Stop before running out, and REPORT it (L-2, H1).
            if (gasleft() < SWEEP_KILL_RESERVE) { status = SWEEP_GAS; break; }
            uint256 n = _openIds.length;
            if (n == 0) break;
            if (cursor >= n) cursor = 0;
            uint256 id = spec != 0 ? pendingIds[scanned] : _openIds[cursor];
            // Re-project per kill, from live spot: every settlement moves it (LIQ04-D).
            if (spec != 0) _projSqrtP = _project(spec, isBuy, limit);
            if (kills == MAX_LIQ_PER_SWAP) {
                Position memory pk = _pos(id);
                if (pk.trader != address(0) && _condemnedByThisTrade(pk)) { status = SWEEP_TOO_LARGE; break; }
                cursor++;
                scanned++;
                continue;
            }
            _tryLiquidate(id, liquidator);
            // A kill swap-popped the LAST id into `cursor`, so re-check that slot; else advance.
            if (_openIds.length < n) { kills++; } else { cursor++; }
            scanned++;
        }

        //  A cascade can condemn what this pass already cleared: every settlement moves spot. Re-read the book until
        //  a full pass finds NOTHING condemned; condemned-but-unclosable (throttled / band-refused) or passes
        //  exhausted is a refusal, never a clean bill of health. Backlog already underwater at spot does not count
        //  ({_condemnedByThisTrade}), so a pre-existing backlog cannot freeze the pool.
        if (spec != 0) {
            bool clean;
            for (uint256 pass; pass < MAX_CASCADE_PASSES && status == SWEEP_OK; ) {
                bool killedAny;
                bool condemnedRemains;
                uint256 m = _openIds.length;
                uint256 i;
                while (i < m) {
                    if (gasleft() < SWEEP_KILL_RESERVE) { status = SWEEP_GAS; break; }
                    uint256 vid = _openIds[i];
                    Position memory pv = _pos(vid);
                    if (pv.trader != address(0) && _condemnedByThisTrade(pv)) {
                        if (kills >= MAX_LIQ_PER_SWAP) { status = SWEEP_TOO_LARGE; break; }
                        _projSqrtP = _project(spec, isBuy, limit);
                        _tryLiquidate(vid, liquidator);
                        if (_openIds.length < m) {
                            unchecked { kills++; }
                            killedAny = true;
                            m = _openIds.length;
                        } else {
                            condemnedRemains = true;
                            unchecked { ++i; }
                        }
                    } else {
                        unchecked { ++i; }
                    }
                }
                if (status != SWEEP_OK) break;
                if (!condemnedRemains) { clean = true; break; }
                if (!killedAny) break;
                unchecked { ++pass; }
            }
            if (status == SWEEP_OK && !clean) status = SWEEP_TOO_LARGE;
        }

        sweepCursor = cursor;
        _inLocked = false;
        _liqReentry = false;
        _projSqrtP = 0;
    }

    /// @dev Condemned BY THE PENDING TRADE: trips at the projected price but NOT at the price the trade found.
    function _condemnedByThisTrade(Position memory p) private returns (bool) {
        (bool trip,,) = _liqTest(p);
        if (!trip) return false;
        uint160 pj = _projSqrtP;
        if (pj == 0) return false;
        _projSqrtP = 0;
        (bool spotTrip,,) = _liqTest(p);
        _projSqrtP = pj;
        return !spotTrip;
    }

    /// @dev Liquidate one position if {_liqTest} trips it and the throttle admits it; else a silent no-op.
    function _tryLiquidate(uint256 id, address liquidator) internal {
        Position memory p = _pos(id);
        if (p.trader == address(0)) return;
        (bool trip, bool insolvent, uint256 notional) = _liqTest(p);
        if (!trip) return;
        if (!_throttle(insolvent, notional)) return;
        _settle(id, p, 0, MODE_LIQUIDATION, liquidator);
    }

    /// @notice Whether a position is liquidatable right now (same test as the sweep).
    function isLiquidatable(uint256 id) external view returns (bool) {
        Position memory p = _pos(id);
        if (p.trader == address(0)) return false;
        (bool trip,,) = _liqTest(p);
        return trip;
    }

    /**
     * @dev THE LIQUIDATION TRIGGER: the TWAP mark with the maintenance buffer (LIQ-01), OR the close-out test.
     *  The mark leg is the ordinary, manipulation-resistant liquidation: it needs a sustained move. The close-out
     *  leg ({_exitInsolvent}) is what rules out bad debt: it fires as soon as closing the position, at the mark or
     *  at spot (inside a pre-trade sweep, at the PROJECTED post-trade price), would no longer repay its debt.
     * @return trip      liquidatable at all
     * @return insolvent the close-out leg fired; exempts the per-timestamp throttle ({_throttle})
     * @return notional  the mark ETH-notional, reused by the throttle (G-02)
     */
    function _liqTest(Position memory p) internal view returns (bool trip, bool insolvent, uint256 notional) {
        uint160 mark = markSqrtPriceX96();
        notional = _quoteAt(p.size, mark);
        trip = _underwaterVal(p, notional);
        uint128 liq = _liq();
        uint256 fee = _hookFeeBps();
        insolvent = _exitInsolvent(p, mark, liq, fee);
        if (!insolvent) {
            uint160 pj = _projSqrtP;
            uint160 sp = pj != 0 ? pj : _sqrtP();
            if (sp != 0) insolvent = _exitInsolvent(p, sp, liq, fee);
        }
        if (insolvent) trip = true;
    }

    /// @dev Would closing `p` at sqrt price `sp` fail to repay its debt? The close is priced at the active depth
    ///      there with the hook's fee on top, as if the position's whole side (the larger of its open interest and
    ///      its cap) were being closed in front of it. Full-range liquidity makes the depth constant along the way.
    function _exitInsolvent(Position memory p, uint160 sp, uint128 liq, uint256 fee) internal view returns (bool) {
        return PerpSwapLib.exitInsolvent(
            p.isLong, p.size, p.principal, uint256(p.collateral) + p.principal,
            sp, liq, p.isLong ? longSizeToken : shortOiToken, p.isLong ? maxOiBps : maxShortOiBps, fee
        );
    }

    /// @dev The hook's fee on this engine's swaps; the hard cap if the hook cannot say (conservative).
    function _hookFeeBps() internal view returns (uint256 fee) {
        (bool ok, bytes memory ret) = hookAddr.staticcall(abi.encodeCall(IPerpFeeView.perpFeeBps, ()));
        if (!ok || ret.length < 32) return HOOK_FEE_CAP_BPS;
        fee = abi.decode(ret, (uint256));
        if (fee > HOOK_FEE_CAP_BPS) fee = HOOK_FEE_CAP_BPS;
    }

    /// @dev An open that trips its own liquidation test is refused rather than liquidated in the post-open sweep.
    function _refuseBornLiquidatable(uint256 id) internal view {
        (bool trip,,) = _liqTest(positions[id]);
        if (trip) revert WouldLiquidate();
    }

    /// @dev Per-timestamp liquidation throttle. INSOLVENT positions are exempt (a throttle must never create
    ///      permanent bad debt, LIQ-01) but still booked against the budget.
    function _throttle(bool insolvent, uint256 notional) internal returns (bool) {
        if (block.timestamp != liqBlock) { liqBlock = block.timestamp; liqEthThisBlock = 0; }
        uint256 cap = (activeEthDepth() * maxLiqBps) / BPS;
        if (!insolvent && cap > 0 && liqEthThisBlock + notional > cap) return false;
        liqEthThisBlock += notional;
        return true;
    }

    /// @dev Underwater at the mark value `val`, with the maintenance buffer.
    function _underwaterVal(Position memory p, uint256 val) internal view returns (bool) {
        if (p.isLong) {
            return val < p.principal + (p.principal * maintenanceBps) / BPS;
        } else {
            uint256 backing = uint256(p.collateral) + p.principal;
            uint256 buffer = (backing * maintenanceBps) / BPS;
            return val + buffer > backing;
        }
    }

    /// @dev The trader's own slippage floor; only a MODE_NORMAL close enforces `minOut`.
    function _ownerFloor(bool on, uint256 got, uint256 minOut) private pure {
        if (on && got < minOut) revert Slippage();
    }

    function _settle(uint256 id, Position memory p, uint256 minOut, uint8 mode, address keeper) internal {
        delete positions[id];
        _removeOpen(id);
        openCount--;
        uint256 residual;
        bool ownerSlippage = mode == MODE_NORMAL;

        if (p.isLong) {
            longOiEth -= p.principal;
            longSizeToken -= p.size;
            (uint256 sold, uint256 proceeds) = _swapExactIn(false, p.size, 0);
            _ownerFloor(ownerSlippage, proceeds, minOut);
            // Exact-input sell of `p.size`: v4 never takes more. Whatever the pool could not take stays as inventory.
            uint256 unsold;
            unchecked { unsold = p.size - sold; }
            if (unsold != 0) { plvToken += unsold; emit TokenDebtWrittenOff(id, unsold); }
            uint256 repay = proceeds >= p.principal ? p.principal : proceeds;
            plv += repay;
            // Long bad debt: replenish plv from insurance (V-01).
            if (proceeds < p.principal) _replenishPlv(p.principal - proceeds);
            residual = proceeds - repay;
        } else {
            // Buy the borrowed token back (price UP), BOUNDED by what the engine may spend (LIQ-02).
            //  E1A: every settlement that can spend staker money (a short's buy-back off a liquidation) is limited
            //  to a band around the TWAP mark, so no price a caller makes in the same transaction can charge the
            //  stakers. What the band refuses is rebooked below, never written off.
            uint160 band = mode != MODE_NORMAL
                ? PerpSwapLib.bandLimit(markSqrtPriceX96(), _sqrtP(), true, true)
                : 0;
            uint256 backing = uint256(p.collateral) + p.principal;
            (uint256 cost, uint256 bought) =
                _buyUpTo(p.size, backing + insuranceEth + plv, band);
            shortOiToken -= bought;
            plvToken += bought;
            // Overspend beyond this position's backing came out of the PLV: absorb it (V-01).
            if (cost > backing) _absorbPlvLoss(cost - backing);
            uint256 unbought = p.size - bought;
            if (unbought > 0) {
                // A partial close rebooks the remaining backing and pays nothing now; only minOut == 0 opts in.
                _ownerFloor(ownerSlippage, 0, minOut);
                _rebook(id, p, unbought, backing > cost ? backing - cost : 0);
                emit PartiallyClosed(id, bought, cost, unbought);
                return;
            }
            residual = backing > cost ? backing - cost : 0;
            _ownerFloor(ownerSlippage, residual, minOut);
        }

        // Funding is a real transfer via the PLV; receivers are paid from insurance first (A-04).
        int256 fd = _fundingDelta(p);
        if (fd > 0) {
            uint256 pay = uint256(fd);
            if (pay > residual) pay = residual;
            plv += pay; residual -= pay;
        } else if (fd < 0) {
            uint256 credit = uint256(-fd);
            uint256 fromIns = credit < insuranceEth ? credit : insuranceEth;
            insuranceEth -= fromIns;
            uint256 rest = credit - fromIns;
            if (rest > plv) rest = plv;
            plv -= rest;
            residual += fromIns + rest;
        }

        if (mode == MODE_LIQUIDATION) {
            uint256 penalty = (uint256(p.collateral) * liqPenaltyBps) / BPS;
            if (penalty > residual) penalty = residual;
            uint256 toKeeper = (penalty * keeperBps) / BPS;
            residual -= penalty;
            _routeFee(penalty - toKeeper, p.isLong);
            if (toKeeper > 0) _payOut(keeper, toKeeper);
            emit Liquidated(id, keeper, penalty);
        }
        if (residual > 0) _payOut(p.trader, residual);
        emit Closed(id, p.trader, residual, int256(residual) - int256(uint256(p.collateral)));
    }

    // ---------------------------------------------------------------------
    // Swaps (real pool impact)
    // ---------------------------------------------------------------------
    /// @dev Open a fresh PoolManager lock, or swap directly when already inside one (in-swap liquidation).
    function _run(SwapReq memory r) internal returns (uint256 spent, uint256 got) {
        if (_inLocked) return _swapBody(r);
        return abi.decode(poolManager.unlock(abi.encode(r)), (uint256, uint256));
    }

    /// @dev Exact-INPUT swap. buy=true spends `amount` ETH for token; buy=false sells `amount` token for ETH.
    function _swapExactIn(bool buy, uint256 amount, uint160 lim)
        internal
        returns (uint256 inDone, uint256 out)
    {
        return _run(SwapReq(buy, false, amount, lim));
    }

    /// @dev Exact-OUTPUT buy of AT MOST `tokenOut` token, spending AT MOST `budget` ETH including the hook fee.
    ///      An unbounded exact-output buy of more token than the pool holds walks the price to the extreme and
    ///      reverts, making the position unclosable at every privilege level (LIQ-02); the limit turns that into a
    ///      partial fill. `budget` is the position's backing, then insurance, then the PLV: the {_absorbPlvLoss}
    ///      waterfall. The pool leg is sized net of the hook's largest possible fee, which the hook adds on top.
    function _buyUpTo(uint256 tokenOut, uint256 budget, uint160 band)
        internal
        returns (uint256 spent, uint256 got)
    {
        uint256 poolBudget = (budget * BPS) / (BPS + HOOK_FEE_CAP_BPS);
        uint160 lim = PerpSwapLib.closeLimit(_sqrtP(), _liq(), poolBudget, true, band);
        (spent, got) = _run(SwapReq(true, true, tokenOut, lim));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotTrader();
        (uint256 spent, uint256 got) = _swapBody(abi.decode(raw, (SwapReq)));
        return abi.encode(spent, got);
    }

    /// @dev The swap itself, shared by the unlock path and the in-lock path. ETH is always currency0.
    function _swapBody(SwapReq memory r) internal returns (uint256, uint256) {
        return PerpSwapLib.swapLeg(
            poolManager,
            poolKey(),
            PerpSwapLib.Req({buy: r.buy, exactOut: r.exactOut, amount: r.amount, limit: r.limit}),
            true,
            ""
        );
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------
    function _openPrologue(uint8 leverage) internal {
        if (msg.value == 0) revert ZeroValue();
        // Without the hook's pre-trade sweep a swap could sink a position past its debt: no opens until it's wired.
        if (IPerpHookView(hookAddr).perpEngine() != address(this)) revert PerpsOff();
        if (leverage < MIN_LEVERAGE || leverage > maxLeverage) revert BadLeverage();
        _pokeFunding();
    }

    function _takeFee(uint256 sent, bool longSide) internal returns (uint256 collateral) {
        uint256 fee = (sent * openFeeBps) / BPS;
        collateral = sent - fee;
        _routeFee(fee, longSide);
    }

    function _checkNotional(uint256 notionalEth) internal view {
        if (notionalEth > (activeEthDepth() * maxNotionalBps) / BPS) revert BadLeverage();
    }

    function _book(address trader, bool isLong, uint256 collateral, uint256 size, uint256 principal, uint8 leverage)
        internal returns (uint256 id)
    {
        if (openCount >= MAX_OPEN_POSITIONS) revert OiCapped();
        id = nextId++;
        _addOpen(id, Position(trader, isLong, uint128(collateral), size, principal,
            uint64(block.timestamp), leverage, fundingIndex));
        emit Opened(id, trader, isLong, collateral, size, leverage);
    }

    /// @dev Write a position and put it into the enumerable open set ({_book} and {_rebook}).
    function _addOpen(uint256 id, Position memory p) internal {
        positions[id] = p;
        openCount++;
        _openIds.push(id); _openPos[id] = _openIds.length;
    }

    /// @dev Put a PARTIALLY closed short back, smaller. Principal is spent first and collateral preserved up to
    ///      the remaining backing, so funding / penalty / keeper bases survive (LIQ-02).
    function _rebook(uint256 id, Position memory p, uint256 newSize, uint256 newBacking) internal {
        p.size = newSize;
        uint256 collateral = p.collateral;
        if (collateral > newBacking) collateral = newBacking;
        p.collateral = uint128(collateral);
        p.principal = newBacking - collateral;
        _addOpen(id, p);
    }

    /// @dev The insurance the live book requires: the greater of the floor and maintenance on open interest.
    function _insuranceNeed() internal view returns (uint256) {
        uint256 riskMin = ((longOiEth + _quoteEth(shortOiToken)) * maintenanceBps) / BPS;
        uint256 floor_ = insuranceFloor;
        return floor_ > riskMin ? floor_ : riskMin;
    }

    /// @dev While a vault is wired: cap each side's utilisation and pause opens while insurance sits below the
    ///      risk-scaled need (M-05). No vault, no gate.
    function _utilGate(uint256 used, uint256 total) private view {
        if (vault == address(0)) return;
        if (used > (total * maxUtilBps) / BPS) revert UtilCapped();
        uint256 need = _insuranceNeed();
        if (need > 0 && insuranceEth < need) revert InsurancePaused();
    }

    /// @dev Remove a settled position from the enumerable open set (swap-and-pop).
    function _removeOpen(uint256 id) internal {
        uint256 idx = _openPos[id];
        if (idx == 0) return;
        uint256 lastId = _openIds[_openIds.length - 1];
        _openIds[idx - 1] = lastId;
        _openPos[lastId] = idx;
        _openIds.pop();
        delete _openPos[id];
    }

    /// @dev Split a fee (open fee, liquidation penalty): LP yield (long side -> `plv`, short side -> `tokYieldEth`),
    ///      insurance, and the rest owed to the fee sink. Pure accounting, no external call. No vault: all to the sink.
    function _routeFee(uint256 amount, bool longSide) internal {
        if (amount == 0) return;
        uint256 toVault;
        uint256 toIns;
        if (vault != address(0)) {
            toVault = (amount * vaultYieldBps) / BPS;
            toIns = (amount * insuranceBps) / BPS;
            if (longSide) {
                plv += toVault;
            } else {
                tokYieldEth += toVault;
                tokYieldCumulative += toVault;
            }
            insuranceEth += toIns;
        }
        uint256 toSink = amount - toVault - toIns;
        feesOwed += toSink;
        emit FeeRouted(toVault, toIns, toSink);
    }

    /// @dev SETTLEMENT-SAFE payout (H-04): credit instead of reverting when the recipient refuses, with a bounded
    ///      gas forward so a recipient cannot eat the settlement's budget.
    function _payOut(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount, gas: 30_000}("");
        if (!ok) {
            unchecked { payoutOwed[to] += amount; payoutOwedTotal += amount; }
            emit PayoutOwed(to, amount);
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthSend();
    }

    /// @notice Withdraw a settlement payout that could not be pushed to you.
    function claimPayout() external nonReentrant returns (uint256 amount) {
        amount = payoutOwed[msg.sender];
        if (amount == 0) revert ZeroValue();
        payoutOwed[msg.sender] = 0;
        payoutOwedTotal -= amount;
        _sendEth(msg.sender, amount);
    }

    /// @notice Send the fee sink its share (machine pot + $IMD). Anyone can call it.
    function flushFees() external nonReentrant notNested returns (uint256 amount) {
        address sink = feeSink;
        amount = feesOwed;
        if (sink == address(0) || amount == 0) revert ZeroValue();
        feesOwed = 0;
        IPerpFeeSink(sink).addPerpFees{value: amount}();
        emit FeesFlushed(sink, amount);
    }

    /// @dev LONG bad debt: `plv` already booked the reduced repayment, so add the insurance cover back.
    function _replenishPlv(uint256 shortfall) internal {
        uint256 cover = shortfall < insuranceEth ? shortfall : insuranceEth;
        if (cover > 0) { insuranceEth -= cover; plv += cover; }
        emit BadDebt(shortfall, cover);
    }

    /// @dev SHORT bad debt: the buy-back overspent by `loss`. Insurance first, then LP principal; whatever outruns
    ///      both becomes a NUMBER in `unabsorbedEth` instead of being dropped (I1).
    function _absorbPlvLoss(uint256 loss) internal {
        uint256 fromIns = loss < insuranceEth ? loss : insuranceEth;
        insuranceEth -= fromIns;
        uint256 rest = loss - fromIns;
        if (rest > 0) {
            uint256 covered = plv < rest ? plv : rest;
            plv -= covered;
            uint256 uncovered = rest - covered;
            if (uncovered != 0) {
                unchecked { unabsorbedEth += uncovered; }
                emit BadDebtUnabsorbed(uncovered, unabsorbedEth);
            }
        }
        emit BadDebt(loss, fromIns);
    }

    function _safeTransfer(address to, uint256 amount) private {
        if (!PerpSwapLib.tryTransfer(token, to, amount)) revert BadParam();
    }

    // ── vault funding + admin ──
    /// @notice Seed the ETH side. Owner-only and share-less: a permanent donation to the PLV (L-02). Community
    ///         capital goes through `PerpVault.depositEth`.
    function fundPlv() external payable onlyOwner notNested {
        plv += msg.value;
        emit PlvFunded(msg.value, 0);
    }

    /// @notice Seed the TOKEN side (lent to shorts). Owner-only, share-less. Caller approves the token first.
    function fundPlvToken(uint256 amount) external onlyOwner notNested {
        _pullTokenIn(amount);
        emit PlvFunded(0, amount);
    }

    function _pullTokenIn(uint256 amount) private {
        if (!PerpSwapLib.tryTransferFrom(token, msg.sender, amount)) revert BadParam();
        plvToken += amount;
    }

    /// @notice Top up the insurance buffer (anyone).
    function fundInsurance() external payable {
        insuranceEth += msg.value;
    }

    // ── Community PLV: vault-only deposit/withdraw ──
    function fundFromVault() external payable onlyVault {
        plv += msg.value;
        emit VaultFunded(true, msg.value);
    }

    /// @notice The vault pulls FREE ETH (<= plv) to pay a withdrawal; lent ETH returns as positions close.
    function withdrawPlvTo(uint256 amount, address to) external onlyVault notNested nonReentrant {
        if (amount > plv) revert PlvInsufficient();
        plv -= amount;
        _sendEth(to, amount);
        emit VaultWithdrawn(true, amount, to);
    }

    /// @notice The vault pulls a token staker's accrued ETH reward out of `tokYieldEth` (never `plv`).
    function withdrawTokYieldTo(uint256 amount, address to) external onlyVault notNested nonReentrant {
        if (amount > tokYieldEth) revert PlvInsufficient();
        tokYieldEth -= amount;
        _sendEth(to, amount);
        emit VaultWithdrawn(true, amount, to);
    }

    function fundTokenFromVault(uint256 amount) external onlyVault {
        _pullTokenIn(amount);
        emit VaultFunded(false, amount);
    }

    /// @notice The vault pulls FREE token inventory (<= plvToken) to pay a withdrawal.
    function withdrawPlvTokenTo(uint256 amount, address to) external onlyVault notNested nonReentrant {
        if (amount > plvToken) revert PlvInsufficient();
        plvToken -= amount;
        _safeTransfer(to, amount);
        emit VaultWithdrawn(false, amount, to);
    }

    function setFees(uint256 _openBps, uint256 _liqBps, uint256 _keeperBps) external onlyOwner {
        if (!(_openBps <= MAX_OPEN_FEE_BPS && _liqBps <= 2000 && _keeperBps <= BPS)) revert BadParam();
        openFeeBps = _openBps; liqPenaltyBps = _liqBps; keeperBps = _keeperBps;
    }

    /// @notice Leverage and depth caps. Funding is bounded so `_pokeFunding` can never overflow or invert (F-04).
    function setRisk(uint8 _maxLeverage, uint256 _maintBps, uint256 _maxNotBps, uint256 _maxOiBps, uint256 _fundingBpsDay)
        external
        onlyOwner
    {
        if (!(_maxLeverage >= MIN_LEVERAGE && _maxLeverage <= MAX_LEVERAGE_CAP && _maintBps <= 5000
            && _maxNotBps <= BPS && _maxOiBps <= BPS && _fundingBpsDay <= BPS)) revert BadParam();
        maxLeverage = _maxLeverage; maintenanceBps = _maintBps;
        maxNotionalBps = _maxNotBps; maxOiBps = _maxOiBps; fundingRateBpsPerDay = _fundingBpsDay;
    }

    /// @notice The short side's own cap and reserve (see {maxShortOiBps})
    function setShortCap(uint256 _maxShortOiBps) external onlyOwner {
        if (_maxShortOiBps > BPS) revert BadParam();
        maxShortOiBps = _maxShortOiBps;
    }

    function setFeeSink(address _feeSink) external onlyOwner {
        feeSink = _feeSink;
    }

    /// @notice Fee split: `_yieldBps` LP yield, `_insBps` insurance, the rest to the fee sink.
    function setVaultSplit(uint256 _yieldBps, uint256 _insBps) external onlyOwner {
        if (_yieldBps + _insBps > BPS) revert BadParam();
        vaultYieldBps = _yieldBps; insuranceBps = _insBps;
    }

    /// @notice TWAP window (1s to 2h), per-timestamp liquidation cap, funding cap.
    function setGuards(uint32 _twapWindow, uint256 _maxLiqBps, uint256 _maxFundingBps) external onlyOwner {
        if (!(_twapWindow >= MIN_TWAP && _twapWindow <= 2 hours && _maxLiqBps <= BPS && _maxFundingBps <= BPS)) revert BadParam();
        twapWindow = _twapWindow; maxLiqBps = _maxLiqBps; maxFundingBps = _maxFundingBps;
    }

    /// @notice Wire the PerpVault. Once wired it can only be re-pointed while nobody holds shares (H-01, R-09).
    function setVault(address _vault) external onlyOwner {
        if (vault != address(0) && IPerpVaultStake(vault).hasStakers()) revert BadParam();
        vault = _vault;
    }

    function setVaultLimits(uint256 _maxUtilBps, uint256 _insuranceFloor) external onlyOwner {
        if (_maxUtilBps > BPS) revert BadParam();
        maxUtilBps = _maxUtilBps; insuranceFloor = _insuranceFloor;
    }

    function setMinCollateral(uint256 _minCollateral) external onlyOwner {
        if (_minCollateral > 1 ether) revert BadParam();
        minCollateral = _minCollateral;
    }

    /// @notice Skim insurance ABOVE what the live book requires (M-05); never depositor principal.
    function skimInsurance(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert BadParam();
        if (insuranceEth < _insuranceNeed() + amount) revert BadParam();
        insuranceEth -= amount;
        _sendEth(to, amount);
    }

    /// @notice Everything the trading UI reads about the market, in one call.
    function market() external view returns (
        uint160 sqrtPriceX96,
        uint160 markX96,
        uint128 liquidity,
        uint256 depthEth,
        uint256 plvEth,
        uint256 plvTok,
        uint256 longOi,
        uint256 longSize,
        uint256 shortOi,
        uint256 insurance,
        uint256 open,
        uint256 hookFee
    ) {
        sqrtPriceX96 = _sqrtP();
        markX96 = markSqrtPriceX96();
        liquidity = _liq();
        depthEth = activeEthDepth();
        (plvEth, plvTok, longOi, longSize, shortOi, insurance, open) =
            (plv, plvToken, longOiEth, longSizeToken, shortOiToken, insuranceEth, openCount);
        hookFee = _hookFeeBps();
    }

    /// @notice Live health of a position for the UI.
    function positionHealth(uint256 id) external view returns (
        bool isLong, uint256 markValueEth, uint256 debtOrBackingEth, bool liquidatable
    ) {
        Position memory p = _pos(id);
        if (p.trader == address(0)) return (false, 0, 0, false);
        isLong = p.isLong;
        markValueEth = _quoteMark(p.size);
        debtOrBackingEth = p.isLong ? p.principal : (uint256(p.collateral) + p.principal);
        (liquidatable,,) = _liqTest(p);
    }

    receive() external payable {}
}
