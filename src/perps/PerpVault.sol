// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IPerpEngineVault {
    function fundFromVault() external payable;
    function token() external view returns (address);
    function withdrawPlvTo(uint256 amount, address to) external;
    function fundTokenFromVault(uint256 amount) external;
    function withdrawPlvTokenTo(uint256 amount, address to) external;
    function totalEth() external view returns (uint256);
    function freeEth() external view returns (uint256);
    function totalTokenAssets() external view returns (uint256);
    function freeToken() external view returns (uint256);
    // side-attributed token-side ETH reward pot
    function tokYieldCumulative() external view returns (uint256);
    /// The POT standing behind that cumulative.
    function tokYieldEth() external view returns (uint256);
    function withdrawTokYieldTo(uint256 amount, address to) external;
}

/**
 * @title PerpVault — Community PLV (LP-for-perps)
 * @notice Anyone can supply the liquidity that backs the perp engine's leverage
 *         and earn REAL yield from it — no team ETH required. Two independent
 *         sides:
 *
 *    • ETH side  — stakers deposit ETH that backs LONGS. Yield = a redirected
 *      slice of the perp OPEN FEE + FUNDING + LIQUIDATION PENALTIES, which the
 *      engine leaves in the PLV so the pot (and thus each share) grows over time.
 *      ETH stakers bear the (insurance-buffered) bad-debt tail risk.
 *
 *    • TOKEN side — stakers deposit the current iteration token that backs
 *      SHORTS (the inventory shorts borrow and must return). Because a short's
 *      buy-back always returns the inventory IN FULL, token principal is
 *      STRUCTURALLY PROTECTED — the ETH shortfall of a bad short is borne by the
 *      ETH side + insurance, never the token side.
 *
 *  ── HOW YIELD SHOWS UP ──────────────────────────────────────────────────────
 *  There is no separate "harvest": fees accrue INSIDE the engine's PLV, so
 *  `engine.totalEth()` / `engine.totalTokenAssets()` grow and the share price
 *  (assets-per-share) rises. Withdrawing later returns more than you put in.
 *
 *  ── WITHDRAWALS UNDER UTILIZATION ───────────────────────────────────────────
 *  Only the UN-LENT portion is instantly withdrawable (the engine caps lending
 *  at `maxUtilBps`, so a buffer is always free). If your withdrawal exceeds the
 *  free buffer, the remainder is QUEUED as a fixed claim and becomes claimable
 *  (`claimPending`) as open positions close and liquidity returns. Queued claims
 *  stop earning yield and stop bearing bad-debt risk the moment they're queued.
 *
 *  Share math uses a virtual offset (à la ERC-4626) so the first deposit and
 *  donation/inflation attacks are handled safely.
 */
contract PerpVault is ReentrancyGuard {
    /// @dev Virtual-shares offset (à la ERC-4626 decimals offset). Shares are
    ///      minted at 1e6× assets, so a first-depositor / donation-inflation
    ///      attack would have to donate ~1e6× a victim's deposit to round their
    ///      shares down — economically infeasible. (Audit V-02)
    uint256 private constant OFFSET = 1e6;
    /// @dev Fixed-point base for the exit-queue index (see the queue note below).
    uint256 private constant QSCALE = 1e27;

    IPerpEngineVault public immutable engine;
    /// @notice The IMD6900 token the token side is staked in (the engine's token)
    address public immutable token;

    //  IMD6900: the quote side is native ETH, always. Cauldron's multi-quote and rotation paths are removed.
    // ── ETH side ──
    uint256 public ethShares;                       // total ETH-side shares
    mapping(address => uint256) public ethShareOf;
    //  ── THE QUEUE IS UNITS x AN INDEX, NOT A BAG OF NOMINALS (red-team NB) ─
    //  A queued exit used to be stored as a wei nominal that {settlePendingEth}
    //  wrote DOWN IN PLACE, per user, against a denominator that still carried
    //  everyone else's full nominal. That made the write-down neither idempotent
    //  nor order-independent: re-aiming it at one address ground his claim toward
    //  zero while every other claimant kept theirs (measured: 80 calls moved
    //  9.878 of 10 ETH from the victim to the caller, for gas), and even ONE
    //  honest call each paid 4.29 / 5.71 depending on who went first.
    //
    //  A claim is now a fixed number of UNITS. A shortfall is recognised ONCE,
    //  globally, by scaling the single `ethQueueIndex` that converts units to wei
    //  ({_syncEthQueue}). No per-user state is touched, so there is nothing to
    //  repeat and no order to depend on: after any sequence of calls every
    //  claimant holds exactly `units * index`, i.e. their pro-rata share.
    //  `pendingEth`/`pendingEthOf` survive as views with their original
    //  signatures, so the ABI and every caller are unchanged.
    uint256 public ethQueueUnits;                   // total outstanding ETH queue units
    uint256 public ethQueueIndex;                   // wei per QSCALE units
    uint64  public ethQueueEpoch;                   // bumped when a queue is wiped out
    /// @notice `engine.totalEth()` as of the last vault action. A fall below this
    ///         that the vault did not cause is a realised loss, and the queue
    ///         bears its share of it (see {_syncEthQueue}, red-team R2A).
    uint256 public ethBackingMark;
    mapping(address => uint256) internal _ethUnitsOf;
    mapping(address => uint64)  internal _ethEpochOf;

    // ── TOKEN side ──
    uint256 public tokShares;                       // total token-side shares
    mapping(address => uint256) public tokShareOf;
    uint256 public tokQueueUnits;                   // total outstanding token queue units
    uint256 public tokQueueIndex;                   // token per QSCALE units
    uint64  public tokQueueEpoch;
    mapping(address => uint256) internal _tokUnitsOf;
    mapping(address => uint64)  internal _tokEpochOf;

    // ── TOKEN-side ETH reward accrual (short-attributed fees, paid in ETH) ──
    /// @dev MasterChef-style accumulator: token stakers earn ETH — the engine's
    ///      short-side LP yield — pro-rata to their token shares, WITHOUT their
    ///      token principal ever converting. Claimed as ETH via {claimTokYield}.
    uint256 private constant ACC = 1e18;
    uint256 public accEthPerTokShare;                 // 1e18-scaled ETH per token-share
    uint256 public lastTokYieldCum;                   // last engine.tokYieldCumulative() folded in
    mapping(address => uint256) public tokRewardDebt; // 1e18-scaled baseline per user
    mapping(address => uint256) public tokRewardOwed; // settled, claimable ETH per user

    //  ── THE WRITE-OFF EPOCH (red-team T3b) ────────────────────────────────
    //  A quote rotation zeroes the engine's `tokYieldEth` pot (PerpEngine.sol:1359)
    //  but deliberately does NOT rewind `tokYieldCumulative`. Every entitlement here
    //  is built out of that cumulative, so a staker who was staked across the
    //  rotation permanently carried an `owed` no pot stood behind — and
    //  {PerpEngine.withdrawTokYieldTo} reverts wholesale on `amount > tokYieldEth`,
    //  so EVERY later claim of theirs reverted, including the yield they genuinely
    //  earned in the NEW quote. Clamping the claim to the pot does not fix it: the
    //  carried nominal then eats the NEXT staker's yield instead.
    //
    //  So the write-off is recognised where it happened, in the accumulator, and the
    //  entitlement it backed is FORFEITED — which is what the engine's own logged
    //  write-off already means. No iteration and no rewind: the vault stamps an
    //  epoch, and a staker still on an older epoch has their pre-write-off `owed`
    //  dropped and their baseline moved to {epochAcc} on their next interaction.
    //  Anything credited AFTER the write-off line survives untouched.
    /// @notice ETH this vault has pulled out of the engine's pot, plus every
    ///         cumulative level already written off. `tokYieldEth() + this` is what
    ///         the cumulative SHOULD be; a shortfall is a rotation write-off.
    uint256 public totalTokYieldPulled;
    /// @notice {accEthPerTokShare} at the moment of the last write-off — the line
    ///         below which entitlements are forfeited and above which they stand.
    uint256 public epochAcc;
    /// @notice Bumped once per observed write-off.
    uint32 public yieldEpoch;
    /// @notice The epoch a staker's `tokRewardDebt`/`tokRewardOwed` were last
    ///         rebased against. Behind {yieldEpoch} == carrying a written-off claim.
    mapping(address => uint32) public stakerEpoch;
    //  ── QUOTE ROTATIONS CONVERT THE YIELD LEDGER, THEY DO NOT FORFEIT IT ────
    //  A rotation used to WRITE OFF `tokYieldEth` (the forfeit machinery above).
    //  {PerpEngine.requoteBook} now converts the pot instead. The per-share side
    //  of this ledger (`accEthPerTokShare`, `epochAcc`, every `debt`/`owed`) is
    //  kept in ONE FIXED internal unit — the quote at genesis — and converted only
    //  at its edges: yield entering through {_syncTokYield} is divided by
    //  {tokYieldScale}, a claim leaving through {claimTokYield} is multiplied by
    //  it. So a rotation touches three totals and nothing per staker.
    //
    //  Rescaling the accumulator itself was the first cut, and it was WRONG:
    //  with the 1e6 share offset the accumulator is ~1e9, and multiplying it by an
    //  ETH→USDG rate of 2.85e-9 floored it to 2 — measured, a 1 ETH claim came
    //  out as 2,000 USDG instead of 2,850 (F12b). Fixed internal units keep full
    //  precision in every era.
    /// @notice Raw quote units per internal unit. IMD6900 has no rotations, so this is fixed at 1e18 and the
    ///         write-off epoch machinery above never fires (`tokYieldEth` only falls when this vault pulls).
    uint256 public constant tokYieldScale = 1e18;

    // Sum of settled reward units in the current yield epoch. Unlike the engine
    // pot, this excludes unattributed yield and accumulator rounding residue.
    uint256 private _settledTokYield;

    event DepositEth(address indexed user, uint256 assets, uint256 shares);
    event WithdrawEth(address indexed user, uint256 shares, uint256 paid, uint256 queued);
    event ClaimEth(address indexed user, uint256 paid);
    event DepositTok(address indexed user, uint256 assets, uint256 shares);
    event WithdrawTok(address indexed user, uint256 shares, uint256 paid, uint256 queued);
    event ClaimTok(address indexed user, uint256 paid);
    event ClaimTokYield(address indexed user, uint256 paid);
    /// @notice The WHOLE exit queue on one side was written down to the backing
    ///         that actually exists. Emitted once per shortfall, not per user:
    ///         every claimant's entitlement is `units * index`, so one index move
    ///         is the entire event. `tokenSide` false = ETH queue.
    event QueueWrittenDown(bool indexed tokenSide, uint256 writtenOff, uint256 newIndex);
    /// @notice Short-side yield that accrued while NO token shares existed. It has no
    ///         rightful claimant and is deliberately NOT back-paid to the next
    ///         depositor; it stays in the engine's segregated pot. (Audit H-05.)
    event UnattributedYield(uint256 amount);
    /// @notice A rotation write-off was observed: every token-side entitlement
    ///         accrued at or below the new {epochAcc} line is forfeited.
    event TokYieldForfeited(uint32 indexed epoch, uint256 amount);

    error ZeroAmount();
    error NotEngine();
    error ZeroShares();
    error InsufficientShares();
    /// The queued-exit nominal outruns the engine's ETH backing; deposits are shut
    /// until the queue banks its haircut through {claimPendingEth}. See {deposit}.
    error QueueInsolvent();
    error TransferFailed();

    constructor(address _engine) {
        engine = IPerpEngineVault(_engine);
        token = IPerpEngineVault(_engine).token();
        ethQueueIndex = QSCALE;
        tokQueueIndex = QSCALE;
    }

    /// @notice Does anyone still have value in this vault — live shares on either
    ///         side, or an unclaimed queued exit?
    ///
    ///  ── THE REPLACEMENT TEST FOR {PerpEngine.setVault} (red-team R-09) ─────
    ///  That guard asked the ENGINE whether its balances were zero
    ///  (`plv != 0 || plvToken != 0 || tokYieldEth != 0`), which conflates
    ///  "someone is owed money" with "a counter is non-zero". Two kinds of
    ///  residue that belong to NOBODY made it unsatisfiable forever:
    ///
    ///    - short-side yield credited while no token shares existed is orphaned
    ///      by design (see the watermark note on {_foldTokYield}), and
    ///      `tokYieldEth` is only ever decremented by paying an attributed
    ///      claim — so an orphan can never be drained; and
    ///    - redemption floors, so ordinary yield leaves one wei of `plv` dust
    ///      behind the last staker.
    ///
    ///  Either one permanently removed the only lever for replacing a buggy vault
    ///  on a live engine. Ownership of value is a question only the vault can
    ///  answer, so it answers it here.
    function hasStakers() external view returns (bool) {
        if ((ethShares | tokShares | ethQueueUnits | tokQueueUnits) != 0) return true;
        // A pending write-off forfeits every already-settled claim. Mirror that
        // lazy invalidation without requiring departed users to transact again.
        return _settledTokYield != 0
            && engine.tokYieldCumulative() <= engine.tokYieldEth() + totalTokYieldPulled;
    }

    // ── asset bases (what backs LIVE shares, net of queued exits) ────────────
    /// @notice ETH backing live shares = engine's ETH PLV minus queued exits.
    function assetsEth() public view returns (uint256) {
        uint256 t = engine.totalEth();
        uint256 p = pendingEth();
        return t > p ? t - p : 0;
    }
    /// @notice Token backing live shares = engine's token inventory minus queued.
    function assetsTok() public view returns (uint256) {
        uint256 t = engine.totalTokenAssets();
        uint256 p = pendingTok();
        return t > p ? t - p : 0;
    }

    // ── ETH side: deposit / withdraw / claim ─────────────────────────────────

    /**
     * @notice Stake to back longs and earn perp fees. Mints shares at the live
     *         assets-per-share (with a virtual offset for safety).
     *
     */
    function depositEth() external payable nonReentrant returns (uint256 shares) {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        _syncEthQueue();   // recognise any loss BEFORE pricing the new shares
        //  ── NO NEW MONEY INTO AN INSOLVENT QUEUE (red-team T3a) ─────────────
        //  {assetsEth} saturates at zero (`:196`), so once `pendingEth` outruns the
        //  engine's backing the share price collapses to the 1-wei OFFSET base and
        //  a fresh depositor mints shares worth ~nothing — while `engine.totalEth()`
        //  jumps by exactly his principal, which {_haircut} (`:263-278`) then hands
        //  to the stale queue in full. Measured: a 10 ETH deposit was worth < 1 gwei
        //  the instant it minted and paid a queue that was already worthless.
        //  The seniority note above says a queued exit is a CLAIM, not a guarantee,
        //  and must bear its share of the loss. Letting a newcomer's principal pay
        //  it instead inverts that. So refuse until the queue has recognised its own
        //  write-down: {settlePendingEth} banks the haircut for ANY queued address,
        //  permissionlessly and without paying anyone (red-team R2C — when only the
        //  claimant himself could bank it, one holdout latched this gate shut), and
        //  {claimPendingEth} banks a zero rather than reverting. Either drains
        //  `pendingEth` and reopens the side. No privilege, no timelock, no stuck vault.
        if (pendingEth() > engine.totalEth()) revert QueueInsolvent();
        // Price BEFORE the engine receives the funds (assetsEth is pre-deposit).
        shares = FullMath.mulDiv(amount, ethShares + OFFSET, assetsEth() + 1);
        if (shares == 0) revert ZeroShares();
        ethShares += shares;
        ethShareOf[msg.sender] += shares;
        engine.fundFromVault{value: amount}();
        _markEth();
        emit DepositEth(msg.sender, amount, shares);
    }

    /// @dev Return values checked: a token that returns false rather than
    ///      reverting would otherwise mint shares for a deposit that never moved.
    function _pull(address asset, address from, uint256 amount) private {
        (bool ok, bytes memory ret) = asset.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amount)
        );
        if (!(ok && (ret.length == 0 || abi.decode(ret, (bool))))) revert ZeroAmount();
    }

    function _approve(address asset, address spender, uint256 amount) private {
        (bool ok, ) = asset.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!ok) revert ZeroAmount();
    }

    /// @notice Redeem ETH shares. Pays instantly up to the engine's FREE ETH; any
    ///         remainder is queued (claim later via {claimPendingEth}).
    function withdrawEth(uint256 shares) external nonReentrant returns (uint256 paid, uint256 queued) {
        _syncEthQueue();   // recognise any loss BEFORE valuing the exit
        uint256 bal = ethShareOf[msg.sender];
        if (shares == 0) revert ZeroShares();
        if (shares > bal) revert InsufficientShares();

        uint256 owed = FullMath.mulDiv(shares, assetsEth() + 1, ethShares + OFFSET);
        uint256 free = engine.freeEth();
        paid = owed <= free ? owed : free;
        queued = owed - paid;
        // EFFECTS first (CEI): burn shares + earmark any queued claim, THEN the
        // single external ETH send. Queued ETH leaves the share base — it stops
        // earning yield AND stops bearing bad-debt risk — and waits for liquidity
        // to free up as positions close.
        ethShareOf[msg.sender] = bal - shares;
        ethShares -= shares;
        if (queued > 0) _queueEth(msg.sender, queued);
        if (paid > 0) engine.withdrawPlvTo(paid, msg.sender); // INTERACTION last
        _markEth();
        emit WithdrawEth(msg.sender, shares, paid, queued);
    }

    /// @dev Write down `owed` if the queue as a whole outruns its backing.
    ///
    ///  ── A QUEUED EXIT IS A CLAIM, NOT A GUARANTEE (red-team L-3) ──────────
    ///  `withdrawEth` converts at-risk SHARES into a fixed nominal claim that
    ///  leaves the share base, so a queued exit stopped bearing bad-debt risk
    ///  while still being first in line for the money. `assetsEth()` saturates at
    ///  zero rather than letting the queue absorb its share of a loss, so every
    ///  wei of a shortfall landed on whoever stayed staked. Measured on the real
    ///  engine: lpA queued 0.4 ETH before a loss and recovered 84%; lpB, who did
    ///  nothing, recovered 0% — and the vault still owed 0.0857 ETH more than the
    ///  engine held. Queueing cost nothing, so it was every LP's dominant move:
    ///  a bank run with a protocol-enforced starting gun.
    ///
    ///  Pro-rata is the honest rule: when backing < claims, each claimant is paid
    ///  `owed * backing / claims` and the rest of their claim is written off, so
    ///  the loss is shared in proportion rather than by reaction speed. Rounds
    ///  DOWN (toward the vault), matching every other division here.
    function _haircut(uint256 owed, uint256 backing, uint256 claims)
        private
        pure
        returns (uint256)
    {
        if (claims == 0 || backing >= claims) return owed;
        return FullMath.mulDiv(owed, backing, claims);
    }

    // ── the exit queue: units, one index, one global write-down ─────────────
    /// @notice Total ETH nominal owed to queued exits. Kept as a view with its
    ///         original name and signature (it used to be a public variable).
    function pendingEth() public view returns (uint256) {
        return FullMath.mulDiv(ethQueueUnits, ethQueueIndex, QSCALE);
    }
    /// @notice `user`'s queued ETH exit, at the live index.
    function pendingEthOf(address user) public view returns (uint256) {
        if (_ethEpochOf[user] != ethQueueEpoch) return 0;
        return FullMath.mulDiv(_ethUnitsOf[user], ethQueueIndex, QSCALE);
    }

    /// @dev Re-baseline the loss mark AFTER this vault moved ETH in or out of the
    ///      engine, so its own transfer is never read as a loss by {_syncEthQueue}.
    function _markEth() private { ethBackingMark = engine.totalEth(); }

    /// @dev A current-quote yield amount into the ledger's fixed internal unit.
    function _toYieldUnit(uint256 v) private view returns (uint256) {
        return FullMath.mulDiv(v, 1e18, tokYieldScale);
    }

    /// @dev Book `amount` of queued ETH for `user` as units at the live index.
    function _queueEth(address user, uint256 amount) private {
        uint256 u = FullMath.mulDiv(amount, QSCALE, ethQueueIndex);
        if (_ethEpochOf[user] != ethQueueEpoch) { _ethEpochOf[user] = ethQueueEpoch; _ethUnitsOf[user] = 0; }
        _ethUnitsOf[user] += u;
        ethQueueUnits += u;
    }

    /// @dev Drop whatever units `user` has left (a claim worth nothing, or one
    ///      paid in full). Keeps the global total in step with the per-user one.
    function _dropEthUnits(address user) private {
        uint256 u = _ethUnitsOf[user];
        if (u == 0) return;
        _ethUnitsOf[user] = 0;
        if (_ethEpochOf[user] == ethQueueEpoch) ethQueueUnits -= u;
    }

    /// @dev Recognise, ONCE and for the WHOLE queue, any shortfall between what
    ///      the queue claims and what the engine actually holds.
    ///
    ///  ── IDEMPOTENT AND ORDER-INDEPENDENT BY CONSTRUCTION (red-team NB) ────
    ///  This takes no user argument and touches no per-user state: it scales the
    ///  single index every claim is measured in. Two consequences the previous
    ///  per-user write-down could not deliver:
    ///
    ///    - IDEMPOTENT. After it runs, `pendingEth() <= engine.totalEth()` (the
    ///      new index is floor(index * backing / claims), so the rescaled total
    ///      cannot exceed `backing`), which is exactly the early-return condition
    ///      on the next call. Call it once or ten thousand times: same state.
    ///    - ORDER-INDEPENDENT. There is no per-user step to order. Every
    ///      claimant's entitlement is `units * index`, and `units` is the
    ///      unchanging nominal they queued. Equal claims are paid equally no
    ///      matter who called what, when, or how often.
    ///
    ///  The pro-rata rule itself is unchanged — see {_haircut}, which is applied
    ///  to the INDEX here instead of to one victim's balance.
    ///
    ///  ── PARI PASSU, NOT SENIOR (red-team R2A) ─────────────────────────────
    ///  The clamp below fires only when the queue outruns the WHOLE backing. For
    ///  any smaller loss it did nothing, and {assetsEth} is the residual
    ///  `totalEth - pendingEth`, so the entire shortfall landed on live shares:
    ///  measured, a 5 ETH loss on a 20 ETH book left the queued LP with 10/10
    ///  (0% of the loss) and the LP who stayed with 5/10 (100% of it), where
    ///  pro-rata is 7.5 each. Queueing was free, so reacting first was every LP's
    ///  dominant move — a bank run with a protocol-enforced starting gun.
    ///
    ///  A drop in `engine.totalEth()` that the vault did not itself cause IS the
    ///  loss, so `ethBackingMark` records the backing as of the last vault action
    ///  and the index is scaled by `backing / mark`. Both sides then fall at the
    ///  same rate: live shares because `assetsEth` is the residual, the queue
    ///  because its index moved. Still ONE global index write, so the idempotence
    ///  and order-independence above are untouched.
    ///
    ///  Every path that moves ETH in or out of the engine re-baselines the mark
    ///  through {_markEth} AFTER its transfer, so a payout is never mistaken for
    ///  a loss. A RISE in backing is not distributed to the queue: a queued exit
    ///  stops earning yield, which is unchanged and deliberate.
    function _syncEthQueue() private {
        uint256 backing = engine.totalEth();
        uint256 units = ethQueueUnits;
        if (units == 0) { ethBackingMark = backing; return; }
        uint256 idx = ethQueueIndex;
        uint256 claims = FullMath.mulDiv(units, idx, QSCALE);
        uint256 mark = ethBackingMark;
        //  (1) pari passu: bear the same proportional loss a live share bears.
        uint256 newIdx = (mark != 0 && backing < mark)
            ? FullMath.mulDiv(idx, backing, mark)
            : idx;
        //  (2) and never carry a claim larger than what exists.
        uint256 c2 = FullMath.mulDiv(units, newIdx, QSCALE);
        if (c2 == 0 || backing < c2) newIdx = c2 == 0 ? 0 : _haircut(newIdx, backing, c2);
        ethBackingMark = backing;
        if (newIdx == idx) return;                             // nothing to recognise
        if (newIdx == 0) {
            //  Nothing the engine holds can pay anyone: retire the whole queue so
            //  it stops blocking {deposit} and {hasStakers} (red-team R2B/R2C).
            //  The epoch bump invalidates every per-user unit balance in O(1).
            ethQueueUnits = 0;
            ethQueueIndex = QSCALE;
            unchecked { ethQueueEpoch++; }
            emit QueueWrittenDown(false, claims, QSCALE);
            return;
        }
        ethQueueIndex = newIdx;
        //  What the queue actually gave up. NOT `claims - backing`: under (1) the
        //  queue can be written down while still fully backed, and that
        //  subtraction underflows (checked arithmetic) exactly then.
        emit QueueWrittenDown(false, claims - FullMath.mulDiv(units, newIdx, QSCALE), newIdx);
    }

    /// @notice Permissionlessly recognise the ETH queue's write-down. Pays nobody.
    ///
    ///  ── ONE HOLDOUT MUST NOT LATCH THE DEPOSIT GATE (red-team R2C) ────────
    ///  `pendingEth` used to shrink ONLY inside {claimPendingEth}, and only for
    ///  `msg.sender`'s own entry. After a death-settle write-off the queue's
    ///  nominal outran `engine.totalEth()`, so {deposit}'s `QueueInsolvent` guard
    ///  shut the ETH side — and the only key was held by a claimant who forfeited
    ///  almost nothing by never turning it (measured: refusing cost the holdout
    ///  0.001 ETH of a 10 ETH claim while shutting deposits for everyone, for the
    ///  life of the engine). Anyone may now turn it. `user` only names a queue
    ///  entry to prune once it is worth nothing; the write-down itself is global,
    ///  so aiming this at an address can neither help nor harm that address
    ///  (red-team NB — it could, and that was a theft).
    ///
    ///  Deliberately does NOT transfer: a queued contract that reverts on
    ///  receive() would otherwise re-create exactly the latch this closes.
    function settlePendingEth(address user) external nonReentrant returns (uint256 stillOwed) {
        _syncEthQueue();
        stillOwed = pendingEthOf(user);
        if (stillOwed == 0) _dropEthUnits(user);
    }

    /// @notice Claim a previously-queued ETH exit as liquidity frees up.
    ///
    ///  Banks the queue-wide write-down first (see {_syncEthQueue}) rather than
    ///  reverting it away: a worthless claim must be recognised as worthless, or
    ///  `pendingEth` can never reach zero and {deposit} stays shut for good
    ///  (red-team H-2 / Jb — both of those reverts are now returns).
    function claimPendingEth() external nonReentrant returns (uint256 paid) {
        if (pendingEthOf(msg.sender) == 0) revert ZeroAmount();
        _syncEthQueue();
        uint256 owed = pendingEthOf(msg.sender);
        if (owed == 0) { _dropEthUnits(msg.sender); emit ClaimEth(msg.sender, 0); return 0; }
        uint256 free = engine.freeEth();
        paid = owed <= free ? owed : free;
        if (paid == 0) { emit ClaimEth(msg.sender, 0); return 0; }
        if (paid >= owed) {
            _dropEthUnits(msg.sender);
        } else {
            uint256 du = FullMath.mulDiv(paid, QSCALE, ethQueueIndex);
            uint256 u = _ethUnitsOf[msg.sender];
            if (du > u) du = u;
            _ethUnitsOf[msg.sender] = u - du;
            ethQueueUnits -= du;
        }
        engine.withdrawPlvTo(paid, msg.sender);
        _markEth();
        emit ClaimEth(msg.sender, paid);
    }

    // ── TOKEN side: deposit / withdraw / claim ───────────────────────────────

    // ── token-side ETH reward accumulator (short-attributed yield) ──
    /// @dev Fold newly-accrued engine token-side yield into the per-share index.
    ///
    ///      ZERO-SHARE HANDLING (audit H-05). Yield that accrued while NOBODY was
    ///      staked has no rightful claimant. The watermark is therefore advanced
    ///      even at zero shares, so it can never be back-paid to whoever happens to
    ///      deposit first. Previously the watermark was left behind, which let a
    ///      watcher deposit one share after a zero-stake window and claim the ENTIRE
    ///      accrued pot regardless of size — ordering, not capital, decided the
    ///      payout. The orphaned ETH stays in the engine's segregated
    ///      `tokYieldEth` pot; governance can redirect it (treasury or insurance).
    ///  ── AND IT DETECTS THE ROTATION WRITE-OFF (red-team T3b) ─────────────
    ///  `tokYieldEth` moves in exactly three ways: up with `tokYieldCumulative` on
    ///  every credit, down by {totalTokYieldPulled} when THIS vault pulls, and down
    ///  by the rotation write-off. So `pot + pulled < cum` is a write-off and
    ///  nothing else, and the gap is exactly how much was lost — no new call, no
    ///  new byte in {PerpEngine}. The lost slice is folded into the accumulator
    ///  FIRST and {epochAcc} stamped at that level, so the forfeit lands on exactly
    ///  the accrual the pot lost and post-rotation yield is preserved for everyone.
    function _syncTokYield() internal {
        uint256 cum = engine.tokYieldCumulative();
        uint256 pulled = totalTokYieldPulled;
        uint256 backed = engine.tokYieldEth() + pulled;
        uint256 lost = cum > backed ? cum - backed : 0;
        uint256 last = lastTokYieldCum;
        uint256 sh = tokShares;
        if (cum != last) {
            lastTokYieldCum = cum;                 // ALWAYS advance
            if (sh == 0) {
                emit UnattributedYield(cum - last);
            } else {
                //  ── THE BOUNDARY IS `>=`, NOT `>` (red-team Ja) ───────────
                //  `cut` is the cumulative level the write-off ate up to. When the
                //  vault happened to be synced AT the rotation, `last` already sat
                //  exactly there, so `cut > last` was false, the split never ran,
                //  and the `else` stamped {epochAcc} at the TOP of the fold —
                //  ABOVE the post-rotation accrual. Every wei of fully-backed NEW
                //  yield was then forfeited on the owner's next interaction and
                //  left stranded in the engine's pot with no claimant. Measured in
                //  Ja_VaultEpochOverForfeit: 2 ETH credited after the write-off,
                //  0 ETH claimable.
                //
                //  `cut` is always within `[last, cum]` — it cannot precede what is
                //  already folded, and it cannot exceed what has been credited —
                //  so clamp it and let the SPLIT be the only shape. `cut == last`
                //  then folds nothing before the line (correct: it is already
                //  there) and `cut == cum` folds nothing after it (correct: no new
                //  yield). Both boundaries fall out instead of being special cases.
                uint256 cut = pulled + lost;
                if (cut < last) cut = last;
                if (cut > cum) cut = cum;
                if (lost != 0) {
                    accEthPerTokShare += FullMath.mulDiv(_toYieldUnit(cut - last), ACC, sh);
                    epochAcc = accEthPerTokShare;  // the forfeit line
                    accEthPerTokShare += FullMath.mulDiv(_toYieldUnit(cum - cut), ACC, sh);
                } else {
                    accEthPerTokShare += FullMath.mulDiv(_toYieldUnit(cum - last), ACC, sh);
                }
            }
        } else if (lost != 0) {
            epochAcc = accEthPerTokShare;
        }
        if (lost != 0) {
            _settledTokYield = 0;
            // Count only the written-off amount. The current backed pot has
            // not been pulled: counting it here masks subsequent write-offs.
            totalTokYieldPulled = pulled + lost;
            unchecked { yieldEpoch++; }
            emit TokYieldForfeited(yieldEpoch, lost);
        }
    }
    /// @dev Bank a user's earned-so-far ETH into their owed balance (call before
    ///      any change to their token-share count).
    function _settleTok(address user) internal {
        //  Carrying a claim from before a write-off? It is forfeited with the pot
        //  that backed it — see the {yieldEpoch} note. The baseline moves to the
        //  write-off line, NOT to today, so post-write-off yield is still earned.
        if (stakerEpoch[user] != yieldEpoch) {
            tokRewardOwed[user] = 0;
            tokRewardDebt[user] = FullMath.mulDiv(tokShareOf[user], epochAcc, ACC);
            stakerEpoch[user] = yieldEpoch;
        }
        uint256 sh = tokShareOf[user];
        if (sh > 0) {
            uint256 acc = FullMath.mulDiv(sh, accEthPerTokShare, ACC);
            if (acc > tokRewardDebt[user]) {
                uint256 earned = acc - tokRewardDebt[user];
                tokRewardOwed[user] += earned;
                _settledTokYield += earned;
            }
        }
    }
    /// @dev Reset a user's reward baseline to their current share count.
    function _resetTokDebt(address user) internal {
        tokRewardDebt[user] = FullMath.mulDiv(tokShareOf[user], accEthPerTokShare, ACC);
    }

    /// @notice Stake the current iteration token to back shorts. Requires an
    ///         approval to this vault. Token principal is structurally protected
    ///         (short buy-backs always return the inventory in full); on top of
    ///         that, you earn ETH from short-side fees (claim via {claimTokYield}).
    function depositToken(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        //  ── NO NEW MONEY INTO AN INSOLVENT TOKEN QUEUE (red-team R2B) ──────
        //  The ETH side has refused this since T3a (`:274`); the token side did
        //  not, and the asymmetry was not cosmetic. {assetsTok} saturates at zero
        //  (`:241`), so once `pendingTok` outruns the engine's inventory a fresh
        //  staker mints against the 1-wei OFFSET base and his ENTIRE principal is
        //  handed to the stale queue by {_haircut}. Measured: 100e18 in, 100e18
        //  straight out to a queue that was already worthless, 0 redeemable.
        //  Release is permissionless and needs no cooperation from the queue:
        //  {settlePendingToken} banks the write-down for any queued address.
        if (pendingTok() > engine.totalTokenAssets()) revert QueueInsolvent();
        address tok = token;
        _syncTokYield(); _settleTok(msg.sender);      // bank rewards at old share count
        shares = FullMath.mulDiv(amount, tokShares + OFFSET, assetsTok() + 1);
        if (shares == 0) revert ZeroShares();
        tokShares += shares;
        tokShareOf[msg.sender] += shares;
        _resetTokDebt(msg.sender);                    // rebase baseline to new count
        // Pull from the user, then let the engine pull from us.
        _pull(tok, msg.sender, amount);
        _approve(tok, address(engine), amount);
        engine.fundTokenFromVault(amount);
        emit DepositTok(msg.sender, amount, shares);
    }

    /// @notice Claim your accrued short-side ETH reward (paid in ETH; your token
    ///         principal stays staked and protected).
    function claimTokYield() external nonReentrant returns (uint256 paid) {
        _syncTokYield(); _settleTok(msg.sender); _resetTokDebt(msg.sender);
        uint256 owed = tokRewardOwed[msg.sender];
        if (owed == 0) revert ZeroAmount();
        paid = FullMath.mulDiv(owed, tokYieldScale, 1e18); // internal → today's quote
        _settledTokYield -= owed;
        tokRewardOwed[msg.sender] = 0;
        totalTokYieldPulled += paid;                  // see {_syncTokYield}'s detector
        if (paid != 0) engine.withdrawTokYieldTo(paid, msg.sender); // from the segregated pot
        emit ClaimTokYield(msg.sender, paid);
    }

    /// @notice Redeem token shares. Pays instantly up to the engine's FREE token
    ///         inventory; any remainder is queued ({claimPendingToken}).
    function withdrawToken(uint256 shares) external nonReentrant returns (uint256 paid, uint256 queued) {
        uint256 bal = tokShareOf[msg.sender];
        if (shares == 0) revert ZeroShares();
        if (shares > bal) revert InsufficientShares();

        _syncTokYield(); _settleTok(msg.sender);      // bank ETH rewards at old count
        uint256 owed = FullMath.mulDiv(shares, assetsTok() + 1, tokShares + OFFSET);
        uint256 free = engine.freeToken();
        paid = owed <= free ? owed : free;
        queued = owed - paid;
        // EFFECTS before the external transfer (CEI).
        tokShareOf[msg.sender] = bal - shares;
        tokShares -= shares;
        _resetTokDebt(msg.sender);                    // rebase baseline to new count
        if (queued > 0) _queueTok(msg.sender, queued);
        if (paid > 0) engine.withdrawPlvTokenTo(paid, msg.sender);
        emit WithdrawTok(msg.sender, shares, paid, queued);
    }

    /// @notice Total token nominal owed to queued exits (view; see {pendingEth}).
    function pendingTok() public view returns (uint256) {
        return FullMath.mulDiv(tokQueueUnits, tokQueueIndex, QSCALE);
    }
    /// @notice `user`'s queued token exit, at the live index.
    function pendingTokOf(address user) public view returns (uint256) {
        if (_tokEpochOf[user] != tokQueueEpoch) return 0;
        return FullMath.mulDiv(_tokUnitsOf[user], tokQueueIndex, QSCALE);
    }

    /// @dev Token twin of {_queueEth}.
    function _queueTok(address user, uint256 amount) private {
        uint256 u = FullMath.mulDiv(amount, QSCALE, tokQueueIndex);
        if (_tokEpochOf[user] != tokQueueEpoch) { _tokEpochOf[user] = tokQueueEpoch; _tokUnitsOf[user] = 0; }
        _tokUnitsOf[user] += u;
        tokQueueUnits += u;
    }

    /// @dev Token twin of {_dropEthUnits}.
    function _dropTokUnits(address user) private {
        uint256 u = _tokUnitsOf[user];
        if (u == 0) return;
        _tokUnitsOf[user] = 0;
        if (_tokEpochOf[user] == tokQueueEpoch) tokQueueUnits -= u;
    }

    /// @dev Token twin of {_syncEthQueue} — one global, idempotent, order-free
    ///      write-down. Same reasoning; see that function's note.
    function _syncTokQueue() private {
        uint256 units = tokQueueUnits;
        if (units == 0) return;
        uint256 idx = tokQueueIndex;
        uint256 claims = FullMath.mulDiv(units, idx, QSCALE);
        uint256 backing = engine.totalTokenAssets();
        if (claims != 0 && backing >= claims) return;
        uint256 newIdx = claims == 0 ? 0 : _haircut(idx, backing, claims);
        if (newIdx == 0) {
            tokQueueUnits = 0;
            tokQueueIndex = QSCALE;
            unchecked { tokQueueEpoch++; }
            emit QueueWrittenDown(true, claims, QSCALE);
            return;
        }
        tokQueueIndex = newIdx;
        emit QueueWrittenDown(true, claims - backing, newIdx);
    }

    /// @notice Token twin of {settlePendingEth} — permissionless, pays nobody.
    function settlePendingToken(address user) external nonReentrant returns (uint256 stillOwed) {
        _syncTokQueue();
        stillOwed = pendingTokOf(user);
        if (stillOwed == 0) _dropTokUnits(user);
    }

    /// @notice Claim a previously-queued token exit as inventory frees up.
    ///
    ///  ── THE TOKEN PATH MIRRORS THE ETH PATH (red-team R2B) ────────────────
    ///  Both branches below used to `revert ZeroAmount()`, which rolled back the
    ///  haircut banked one line up — the exact defect the ETH side had closed and
    ///  never propagated here. Once token backing fell under `pendingTok` the
    ///  token queue could never shrink: `hasStakers()` stayed true forever, so
    ///  {PerpEngine.setVault} could never replace a buggy vault for the life of
    ///  the engine. Bank the write-down and return, exactly as {claimPendingEth}.
    function claimPendingToken() external nonReentrant returns (uint256 paid) {
        if (pendingTokOf(msg.sender) == 0) revert ZeroAmount();
        _syncTokQueue();
        uint256 owed = pendingTokOf(msg.sender);
        if (owed == 0) { _dropTokUnits(msg.sender); emit ClaimTok(msg.sender, 0); return 0; }
        uint256 free = engine.freeToken();
        paid = owed <= free ? owed : free;
        if (paid == 0) { emit ClaimTok(msg.sender, 0); return 0; }
        if (paid >= owed) {
            _dropTokUnits(msg.sender);
        } else {
            uint256 du = FullMath.mulDiv(paid, QSCALE, tokQueueIndex);
            uint256 u = _tokUnitsOf[msg.sender];
            if (du > u) du = u;
            _tokUnitsOf[msg.sender] = u - du;
            tokQueueUnits -= du;
        }
        engine.withdrawPlvTokenTo(paid, msg.sender);
        emit ClaimTok(msg.sender, paid);
    }

    // ── frontend views ───────────────────────────────────────────────────────

    /// @notice ETH currently redeemable for `user`'s shares (at the live price),
    ///         and how much of it is instantly withdrawable right now.
    function ethPosition(address user) external view returns (uint256 redeemable, uint256 instant, uint256 pending) {
        uint256 s = ethShareOf[user];
        redeemable = FullMath.mulDiv(s, assetsEth() + 1, ethShares + OFFSET);
        uint256 free = engine.freeEth();
        instant = redeemable <= free ? redeemable : free;
        pending = pendingEthOf(user);
    }
    /// @notice Token currently redeemable for `user`'s shares + instant portion.
    function tokenPosition(address user) external view returns (uint256 redeemable, uint256 instant, uint256 pending) {
        uint256 s = tokShareOf[user];
        redeemable = FullMath.mulDiv(s, assetsTok() + 1, tokShares + OFFSET);
        uint256 free = engine.freeToken();
        instant = redeemable <= free ? redeemable : free;
        pending = pendingTokOf(user);
    }
    /// @notice A token staker's accrued short-side ETH reward, claimable now
    ///         (includes yield not yet folded into the accumulator).
    function pendingTokYield(address user) external view returns (uint256) {
        uint256 acc = accEthPerTokShare;
        uint256 eAcc = epochAcc;
        uint32 ep = yieldEpoch;
        uint256 cum = engine.tokYieldCumulative();
        uint256 pulled = totalTokYieldPulled;
        uint256 lost;
        { uint256 backed = engine.tokYieldEth() + pulled;
          lost = cum > backed ? cum - backed : 0; }
        uint256 last = lastTokYieldCum;
        uint256 shTot = tokShares;
        // Mirrors _syncTokYield exactly: at zero shares the delta is unattributed and
        // is NOT credited to anyone, so the view must not promise it either (H-05).
        //  ── AND IT MIRRORS THE WRITE-OFF TOO (red-team T3b) ────────────────
        //  A view that reported the pre-write-off nominal while {claimTokYield}
        //  paid the post-write-off one would be the same lie the bug was, moved
        //  into the UI. Same detector, same split fold, same epoch line.
        if (cum != last) {
            if (shTot != 0) {
                uint256 cut = pulled + lost;        // same clamp+split as _syncTokYield
                if (cut < last) cut = last;
                if (cut > cum) cut = cum;
                if (lost != 0) {
                    acc += FullMath.mulDiv(_toYieldUnit(cut - last), ACC, shTot);
                    eAcc = acc;
                    acc += FullMath.mulDiv(_toYieldUnit(cum - cut), ACC, shTot);
                } else {
                    acc += FullMath.mulDiv(_toYieldUnit(cum - last), ACC, shTot);
                }
            }
        } else if (lost != 0) {
            eAcc = acc;
        }
        if (lost != 0) ep++;                       // the bump the next sync will make

        uint256 sh = tokShareOf[user];
        uint256 owed = tokRewardOwed[user];
        uint256 debt = tokRewardDebt[user];
        if (stakerEpoch[user] != ep) { owed = 0; debt = FullMath.mulDiv(sh, eAcc, ACC); }
        uint256 earned;
        if (sh > 0) { uint256 a = FullMath.mulDiv(sh, acc, ACC); if (a > debt) earned = a - debt; }
        //  Internal units → today's quote, exactly as {claimTokYield} pays it.
        return FullMath.mulDiv(owed + earned, tokYieldScale, 1e18);
    }

    // ── internal ERC20 helpers ────────────────────────────────────────────────
}
