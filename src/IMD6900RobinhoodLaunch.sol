// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMD6900} from "./IMD6900.sol";
import {IMD6900Hook} from "./IMD6900Hook.sol";
import {IMD6900LockedPool} from "./IMD6900LockedPool.sol";

/// @title IMD6900RobinhoodLaunch - Identity.MD 6900 (IMD6900) on Robinhood Chain: the coin, its locked Uniswap v4 pool
///        with the perps hook, the opening buy, the 1:1 claim for the old IMDSTR, the fee split
/// @notice Deployed by the IMD swarm. Its constructor creates the locked pool and calls nothing that existed before
///         it. Then:
///          0. {createHook} (anyone, once): the hook, with CREATE2 from here, at a salt mined off-chain for this
///             contract's address so the hook's address carries exactly its permissions (never 0x91…, so Uniswap
///             routes the pool on its own). Every salt it accepts makes the same hook: same code, permissions, owner;
///          1. the team sends the opening buy's ETH (or sends it with {launch}); {withdrawEth} takes it back until then
///             (after it, the timelock can sell the coins held here back into the pool for it: {sellHeld});
///          2. the owner sets the claim list ({setClaims}: a Merkle root of the snapshot's IMDSTR balances) and mines
///             the coin's vanity address for THIS contract (it deploys the coin with CREATE2);
///          3. {launch}, one transaction, so nobody trades before it: the coin (1B, minted here), the pool opened with
///             all of it as IMD6900-only liquidity from the opening price down (no ETH needed, locked for good), the
///             opening buy with every wei held here, the claims' reserve kept, the rest kept here too (only the
///             Robinhood timelock can release it: {releaseExcess}), or burned, or sent where the launch says.
///         Claims: IMDSTR in, IMD6900 out, 1:1, up to each holder's snapshot balance. IMDSTR moves only to and from
///         Robinhood distributors, so claiming opens once the Robinhood timelock makes this contract one.
///         Fees: the pool's static 4.44% (the timelock can move the liquidity to a lower-fee pool, never higher)
///         accrues to its locked position. {harvest} (anyone) collects it (the IMD6900 part is
///         burned by the pool) and splits the ETH: 90% to the pot bridge (IMD6900's NFT floor pot on Ethereum), 10% to
///         $IMD's canonical burn, until the Robinhood timelock sets other payees ({setPayees}, behind its delay). The $IMD
///         share is kept here and {burnImd} (anyone) spends it,
///         at most {IMD_BUY_MAX} a call, buying $IMD on its Robinhood pool for IMD's official burn executor there,
///         which bridges it to Base to be destroyed. After the launch, ETH leaves only through the split, the $IMD
///         buys, or the timelock's {recoverEth}.
contract IMD6900RobinhoodLaunch is Ownable, ReentrancyGuard {
    /// @dev beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, afterSwap: no return deltas, no
    ///      dynamic fee, nothing that would cost the pool Uniswap's automatic routing
    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    /// @notice The pool's opening fee, hundredths of a bip: 4.44%, static (so Uniswap routes the pool on its own).
    ///         Only the Robinhood timelock can lower it (IMD6900LockedPool.lowerFee), never raise it.
    uint24 public constant POOL_FEE = 44_400;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    /// @notice PonsPotBridge on Robinhood: bridges ETH (Across) to the Ethereum launch hook, which feeds IMD6900's NFT pot
    address public constant POT_BRIDGE = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    uint16 public constant POT_BPS = 9_000;
    /// @notice $IMD (Identity.md) on Robinhood Chain, and its official burn executor there (it bridges what it holds to
    ///         IMD's burn receiver on Base). As a payee, the executor's share buys $IMD rather than being sent as ETH.
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant IMD_BURN = 0x4D6537ec564aFf82eABb1Ce5f355E817cBEA1e07;
    /// @notice The coin's address starts with this (its top 16 bits): {launch} refuses any other
    uint16 public constant VANITY = 0x6900;
    uint16 public constant IMD_BPS = 1_000;
    /// @notice The most {burnImd} spends per block timestamp (one call a timestamp, so one transaction, or one block,
    ///         can never spend more): under what sandwiching it would be worth through two 1% fees
    uint256 public constant IMD_BUY_MAX = 0.1 ether;
    uint256 public constant MAX_PAYEES = 8;
    /// @notice Claims stay open at least this long after the launch before the unclaimed reserve can be released
    uint256 public constant MIN_CLAIM_WINDOW = 90 days;

    IPoolManager public immutable poolManager;
    IMD6900LockedPool public immutable pool;
    /// @notice The pool's hook, once {createHook} made it
    IMD6900Hook public hook;
    bytes32 public hookSalt;
    /// @notice Robinhood's IMDSTR, the old token that claims IMD6900 1:1
    address public immutable imdstr;
    /// @notice The Robinhood timelock: owns the hook; after the launch it alone moves the coins held here (selling them
    ///         back for the opening buy's ETH, {sellHeld}), ends the claims early, and recovers ETH besides the split
    address public immutable timelock;

    /// @notice IMD6900, once launched
    address public token;
    uint256 public launchEth;
    uint256 public launchBought;
    /// @notice What the opening buy landed beyond the claims' reserve: kept here, burned, or sent where the launch said
    uint256 public launchExcess;
    /// @notice The coins held here for the Robinhood timelock (the excess, and the unclaimed reserve once it ends the
    ///         claims): only it moves them, sold back into the pool ({sellHeld}) or released ({releaseExcess})
    uint256 public excessHeld;

    /// @notice The claim list: a Merkle root of (account, IMDSTR balance) at the snapshot, their sum, and when the
    ///         unclaimed rest may be released. Set before the launch, fixed after.
    bytes32 public claimRoot;
    uint256 public claimTotal;
    uint256 public claimDeadline;
    uint256 public claimedTotal;
    bool public unclaimedReleased;
    mapping(address => uint256) public claimedBy;

    /// @notice ETH set aside for $IMD's burn, spent by {burnImd}; and what it has bought and sent so far
    uint256 public imdBucket;
    uint256 public imdBurned;
    /// @notice The block timestamp of the last {burnImd}: one buy a timestamp
    uint256 public lastImdBuy;
    /// @notice $IMD's Robinhood pool: ETH / $IMD at this fee, tick spacing and hooks (the timelock may repoint it)
    uint24 public imdPoolFee = 10_000;
    int24 public imdPoolTickSpacing = 100;
    address public imdPoolHooks;

    /// @notice IMD's burn executor on Robinhood, where the $IMD share goes: the canonical one ({IMD_BURN}) unless the
    ///         timelock repoints it ({setImdBurn}), should IMD ever move it
    address public imdBurn = IMD_BURN;
    /// @notice Where the perps engine's fees go (what its stakers and insurance don't keep): all of it as ETH to the pot
    ///         bridge, so the NFT floor pot on Ethereum, unless the timelock repoints it ({setPerpFeeTo})
    address public perpFeeTo = POT_BRIDGE;
    /// @notice Perps fees {perpFeeTo} refused ({addPerpFees}): kept here and offered again with the next forwarding,
    ///         to wherever {perpFeeTo} points then; never split. Cancelled only by the timelock's {recoverEth}.
    uint256 public perpFeesOwed;

    /// @dev The timelock's payees once set (fixed-size); until then 90% the pot bridge, 10% $IMD's burn
    address[8] internal _payees;
    uint16[8] internal _shares;
    uint8 internal _payeeCount;
    /// @notice ETH a payee refused ({split}): kept here for it and offered again with its next share, never divided
    ///         among the others. Per payee, and their sum. Cancelled (divided again at the next split) only when the
    ///         timelock drops the payee ({setPayees}) or recovers the ETH ({recoverEth}).
    mapping(address => uint256) public owed;
    uint256 public owedTotal;

    event HookCreated(address hook, bytes32 salt);
    event ClaimsSet(bytes32 root, uint256 total, uint256 deadline);
    event EthWithdrawn(address to, uint256 amount);
    event Launched(
        address token,
        uint160 sqrtPriceX96,
        int24 upperTick,
        uint256 ethSpent,
        uint256 bought,
        uint256 excess,
        address excessTo
    );
    event Claimed(address indexed account, uint256 amount);
    event UnclaimedReleased(address to, uint256 amount);
    event ImdstrReleased(address to, uint256 amount);
    event FeesReceived(address indexed from, uint256 amount);
    event Split(uint256 amount);
    event PayFailed(address payee, uint256 amount);
    event OwedCancelled(address payee, uint256 amount);
    event PayeesSet(address[] payees, uint16[] shares);
    event EthRecovered(address to, uint256 amount);
    event ExcessReleased(address to, uint256 amount);
    event ClaimsEnded(uint256 unclaimed);
    event HeldSold(uint256 coins, uint256 eth, address to);
    event ImdBurned(uint256 ethIn, uint256 imd);
    event ImdPoolSet(uint24 fee, int24 tickSpacing, address hooks);
    event ImdBurnSet(address executor);
    event PerpFeeToSet(address to);
    event PerpFeesForwarded(address to, uint256 amount);

    error HookExists();
    error BadHook();
    error AlreadyLaunched();
    error NotLaunched();
    error NoEth();
    error NotWhereMined(address token);
    error NotVanity(address token);
    error Short(uint256 bought);
    error BadClaims();
    error BadProof();
    error OverClaim();
    error ZeroAmount();
    error ClaimsOpen();
    error AlreadyReleased();
    error BadPayees();
    error NotTimelock();
    error OnlyPoolManager();
    error BoughtThisBlock();
    error NoRenounce();

    /// @param owner_       the team wallet: launches, sets the claim list and the payees
    /// @param poolManager_ Uniswap v4's PoolManager on Robinhood Chain
    /// @param imdstr_      Robinhood's IMDSTR
    /// @param timelock_    the Robinhood timelock: the hook's owner, and {recoverEth}
    constructor(address owner_, IPoolManager poolManager_, address imdstr_, address timelock_) {
        _initializeOwner(owner_);
        poolManager = poolManager_;
        imdstr = imdstr_;
        timelock = timelock_;
        pool = new IMD6900LockedPool(poolManager_, POOL_FEE, address(this), timelock_);
    }

    /*                              THE HOOK                                */

    /// @notice Creates the hook at `salt` and wires the pool to it; anyone, once. The salt is mined off-chain
    ///         (script/launch.sh hook): its CREATE2 address from here, for {hookInitCodeHash}, must carry exactly
    ///         {FLAGS} in its low 14 bits and not start with 0x91. Mining it here instead would cost the deploy a random
    ///         ~2.6M gas on average and, about one address in fifty, more than a transaction can hold.
    function createHook(bytes32 salt) external returns (IMD6900Hook) {
        if (address(hook) != address(0)) revert HookExists();
        bytes memory init = _hookInitCode();
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(init, 0x20), mload(init), salt)
        }
        if (h == address(0) || uint160(h) & Hooks.ALL_HOOK_MASK != FLAGS || uint160(h) >> 152 == 0x91) {
            revert BadHook();
        }
        pool.setHook(h);
        hook = IMD6900Hook(h);
        hookSalt = salt;
        emit HookCreated(h, salt);
        return IMD6900Hook(h);
    }

    /// @notice keccak256 of the hook's creation code with its constructor arguments: the init code hash to mine against
    function hookInitCodeHash() external view returns (bytes32) {
        return keccak256(_hookInitCode());
    }

    /// @notice Before the launch, the opening buy's ETH (anyone may send it, only the owner takes it back); after, fees
    receive() external payable {}

    /// @notice The pool's ETH fees (IMD6900LockedPool.collect)
    function addFees() external payable {
        emit FeesReceived(msg.sender, msg.value);
    }

    /// @notice The perps engine's fees (PerpEngine.flushFees, with this contract as its fee sink): straight on to
    ///         {perpFeeTo}, none of it split. What it refuses is kept here for it ({perpFeesOwed}) and offered again
    ///         with the next forwarding, so a refusing destination never blocks the engine's flush.
    function addPerpFees() external payable {
        address to = perpFeeTo;
        uint256 pay = msg.value + perpFeesOwed;
        if (pay == 0) return;
        (bool ok,) = to.call{value: pay}("");
        if (ok) {
            perpFeesOwed = 0;
            emit PerpFeesForwarded(to, pay);
        } else {
            perpFeesOwed = pay;
            emit PayFailed(to, pay);
        }
    }

    /// @notice Never: the launch, the claims and the held coins must always have an owner (as the hook and the engine)
    function renounceOwnership() public payable override {
        revert NoRenounce();
    }

    /// @notice The coin's address for `salt`: what the owner mines a vanity salt against
    function tokenAddress(bytes32 salt) public view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(IMD6900).creationCode, abi.encode(address(this))))
            )
        );
        return address(uint160(uint256(h)));
    }

    /// @notice keccak256 of the coin's creation code with its constructor argument: the init code hash to mine against
    function tokenInitCodeHash() external view returns (bytes32) {
        return keccak256(abi.encodePacked(type(IMD6900).creationCode, abi.encode(address(this))));
    }

    function payees() public view returns (address[] memory to, uint16[] memory bps) {
        uint256 n = _payeeCount;
        if (n == 0) {
            (to, bps) = (new address[](2), new uint16[](2));
            (to[0], bps[0], to[1], bps[1]) = (POT_BRIDGE, POT_BPS, imdBurn, IMD_BPS);
            return (to, bps);
        }
        (to, bps) = (new address[](n), new uint16[](n));
        for (uint256 i; i < n; ++i) {
            (to[i], bps[i]) = (_payees[i], _shares[i]);
        }
    }

    /// @notice What is still reserved for claims
    function claimReserve() public view returns (uint256) {
        return unclaimedReleased ? 0 : claimTotal - claimedTotal;
    }

    /*                                 OWNER                                */

    /// @notice The claim list, before the launch: `root` over leaves keccak256(keccak256(abi.encode(account, amount))),
    ///         `total` their sum (the reserve the opening buy must cover), `deadline` when the unclaimed rest may be
    ///         released (at least {MIN_CLAIM_WINDOW} after the launch; checked then)
    function setClaims(bytes32 root, uint256 total, uint256 deadline) external onlyOwner {
        if (token != address(0)) revert AlreadyLaunched();
        if ((root == bytes32(0)) != (total == 0)) revert BadClaims();
        (claimRoot, claimTotal, claimDeadline) = (root, total, deadline);
        emit ClaimsSet(root, total, deadline);
    }

    /// @notice Sends ETH held here to `to` (all of it with 0): the way out of a launch the team decides against.
    ///         Before the launch only.
    function withdrawEth(address to, uint256 amount) external onlyOwner nonReentrant {
        if (token != address(0)) revert AlreadyLaunched();
        if (amount == 0) amount = address(this).balance;
        if (amount == 0) revert NoEth();
        SafeTransferLib.safeTransferETH(to, amount);
        emit EthWithdrawn(to, amount);
    }

    /// @notice The launch, in one transaction: creates the coin at the CREATE2 address `salt` gives (reverts unless
    ///         it is `expectedToken`), opens the pool at `sqrtPriceX96` (coin per ETH, rounded down onto a tick) with
    ///         the whole supply, buys with every wei held here (the ETH sent included), keeps the claims' reserve, and
    ///         keeps the rest here for the timelock (`excessTo` this contract), burns it (`excessTo` zero) or sends it
    ///         to `excessTo`.
    /// @param minBought the opening buy's floor; it must cover the claims' reserve in any case
    function launch(bytes32 salt, address expectedToken, uint160 sqrtPriceX96, uint256 minBought, address excessTo)
        external
        payable
        onlyOwner
        nonReentrant
        returns (address t, uint256 bought)
    {
        if (token != address(0)) revert AlreadyLaunched();
        if (claimTotal != 0 && claimDeadline < block.timestamp + MIN_CLAIM_WINDOW) revert BadClaims();
        t = address(new IMD6900{salt: salt}(address(this)));
        if (t != expectedToken) revert NotWhereMined(t);
        if (uint160(t) >> 144 != VANITY) revert NotVanity(t);
        token = t;

        SafeTransferLib.safeApprove(t, address(pool), SUPPLY);
        pool.open(t, sqrtPriceX96, SUPPLY);

        uint256 spend = address(this).balance;
        if (spend == 0) revert NoEth();
        (bought,) = abi.decode(poolManager.unlock(abi.encode(uint8(0), spend)), (uint256, uint256));
        if (bought < minBought || bought < claimTotal) revert Short(bought);

        uint256 excess = SafeTransferLib.balanceOf(t, address(this)) - claimTotal; // the opening's rounding dust included
        if (excess != 0) {
            if (excessTo == address(this)) excessHeld = excess;
            else if (excessTo == address(0)) IMD6900(t).burn(excess);
            else SafeTransferLib.safeTransfer(t, excessTo, excess);
        }
        (launchEth, launchBought, launchExcess) = (spend, bought, excess);
        emit Launched(t, sqrtPriceX96, pool.upperTick(), spend, bought, excess, excessTo);
    }

    /// @notice After the claim deadline, the unclaimed reserve: burned (`to` zero) or sent to `to`. Once.
    function releaseUnclaimed(address to) external onlyOwner nonReentrant {
        if (token == address(0)) revert NotLaunched();
        if (block.timestamp < claimDeadline) revert ClaimsOpen();
        if (unclaimedReleased) revert AlreadyReleased();
        uint256 amount = claimTotal - claimedTotal;
        unclaimedReleased = true;
        if (amount != 0) {
            if (to == address(0)) IMD6900(token).burn(amount);
            else SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit UnclaimedReleased(to, amount);
    }

    /// @notice The IMDSTR the claims collected (all of it with 0), to `to`: home to Ethereum, where it is IMD6900
    function releaseImdstr(uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 held = SafeTransferLib.balanceOf(imdstr, address(this));
        if (amount == 0) amount = held;
        if (amount == 0 || amount > held) revert ZeroAmount();
        SafeTransferLib.safeTransfer(imdstr, to, amount);
        emit ImdstrReleased(to, amount);
    }

    /*                        THE ROBINHOOD TIMELOCK                        */

    /// @notice Who the ETH fees are split to: up to {MAX_PAYEES}, shares in basis points summing to 10,000. IMD's burn
    ///         executor as a payee means its share buys $IMD for it. Only the Robinhood timelock, behind its delay.
    function setPayees(address[] calldata to, uint16[] calldata bps) external {
        if (msg.sender != timelock) revert NotTimelock();
        uint256 n = to.length;
        if (n == 0 || n > MAX_PAYEES || n != bps.length) revert BadPayees();
        (address[] memory old,) = payees(); // before the new list replaces it
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (to[i] == address(0)) revert BadPayees();
            (_payees[i], _shares[i]) = (to[i], bps[i]);
            sum += bps[i];
        }
        if (sum != 10_000) revert BadPayees();
        _payeeCount = uint8(n);
        // what a payee the new list drops was owed is cancelled: the next split divides it among the new payees
        for (uint256 i; i < old.length; ++i) {
            bool kept;
            for (uint256 j; j < n && !kept; ++j) {
                kept = to[j] == old[i];
            }
            if (!kept) _cancelOwed(old[i]);
        }
        emit PayeesSet(to, bps);
    }

    /// @notice Sends ETH held here to `to` (all of it with 0), at any time, behind the timelock's delay: the escape
    ///         hatch for the fees (a payee that refused its share, a split to stop)
    function recoverEth(address to, uint256 amount) external nonReentrant {
        if (msg.sender != timelock) revert NotTimelock();
        if (amount == 0) amount = address(this).balance;
        if (amount == 0) revert NoEth();
        SafeTransferLib.safeTransferETH(to, amount);
        uint256 left = address(this).balance;
        if (imdBucket + owedTotal + perpFeesOwed > left) {
            // what was booked is gone with it: the payees' owed shares and the perps' first, then what was set aside
            // for $IMD
            (address[] memory ps,) = payees();
            for (uint256 i; i < ps.length; ++i) {
                _cancelOwed(ps[i]);
            }
            perpFeesOwed = 0;
            if (imdBucket > left) imdBucket = left;
        }
        emit EthRecovered(to, amount);
    }

    /// @notice Releases `amount` (all of it with 0) of the excess the launch kept here, to `to` (burned with zero):
    ///         behind the timelock's delay, public for all of it
    function releaseExcess(uint256 amount, address to) external nonReentrant {
        if (msg.sender != timelock) revert NotTimelock();
        if (amount == 0) amount = excessHeld;
        if (amount == 0 || amount > excessHeld) revert ZeroAmount();
        excessHeld -= amount;
        if (to == address(0)) IMD6900(token).burn(amount);
        else SafeTransferLib.safeTransfer(token, to, amount);
        emit ExcessReleased(to, amount);
    }

    /// @notice Ends the claims now: the unclaimed reserve joins the coins held for the timelock ({sellHeld},
    ///         {releaseExcess}). Behind its public delay, so every holder sees it coming and can claim before it runs.
    function endClaims() external {
        if (msg.sender != timelock) revert NotTimelock();
        if (token == address(0)) revert NotLaunched();
        if (unclaimedReleased) revert AlreadyReleased();
        uint256 unclaimed = claimTotal - claimedTotal;
        unclaimedReleased = true;
        claimDeadline = block.timestamp;
        excessHeld += unclaimed;
        emit ClaimsEnded(unclaimed);
    }

    /// @notice Sells `amount` (all of it with 0) of the coins held for the timelock back into the pool, the ETH to
    ///         `to`: how the opening buy's ETH comes back, at the price the market left. Fee-free (the locked pool refunds
    ///         it, IMD6900LockedPool.feeRefund); the opening buy's own fee went to the split. Behind the timelock's delay;
    ///         `minEth` is the floor. What the pool can't take stays held.
    function sellHeld(uint256 amount, uint256 minEth, address to) external nonReentrant returns (uint256 eth) {
        if (msg.sender != timelock) revert NotTimelock();
        if (amount == 0) amount = excessHeld;
        if (amount == 0 || amount > excessHeld) revert ZeroAmount();
        uint256 sold;
        (eth, sold) = abi.decode(poolManager.unlock(abi.encode(uint8(2), amount)), (uint256, uint256));
        if (eth < minEth) revert Short(eth);
        excessHeld -= sold;
        SafeTransferLib.safeTransferETH(to, eth);
        emit HeldSold(sold, eth, to);
    }

    /// @notice Repoints the $IMD share to another burn executor (set the payees again if they name the old one)
    function setImdBurn(address executor) external {
        if (msg.sender != timelock) revert NotTimelock();
        if (executor == address(0)) revert BadPayees();
        imdBurn = executor;
        _cancelOwed(executor); // its share is set aside for {burnImd} from now on, not sent
        emit ImdBurnSet(executor);
    }

    /// @notice Repoints the perps engine's fees
    function setPerpFeeTo(address to) external {
        if (msg.sender != timelock) revert NotTimelock();
        if (to == address(0) || to == address(this)) revert BadPayees();
        perpFeeTo = to;
        emit PerpFeeToSet(to);
    }

    /// @notice Repoints $IMD's buys to another of its Robinhood pools (ETH / $IMD), behind the timelock's delay
    function setImdPool(uint24 fee, int24 tickSpacing, address hooks) external {
        if (msg.sender != timelock) revert NotTimelock();
        (imdPoolFee, imdPoolTickSpacing, imdPoolHooks) = (fee, tickSpacing, hooks);
        emit ImdPoolSet(fee, tickSpacing, hooks);
    }

    /*                                ANYONE                                */

    /// @notice IMDSTR in, IMD6900 out, 1:1, up to the caller's snapshot balance `allowance` (approve IMDSTR first).
    ///         The IMDSTR stays here.
    function claim(uint256 amount, uint256 allowance, bytes32[] calldata proof) external nonReentrant {
        if (token == address(0)) revert NotLaunched();
        if (amount == 0) revert ZeroAmount();
        if (unclaimedReleased) revert AlreadyReleased();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, allowance))));
        if (!_verify(proof, claimRoot, leaf)) revert BadProof();
        uint256 done = claimedBy[msg.sender] + amount;
        uint256 total = claimedTotal + amount;
        if (done > allowance || total > claimTotal) revert OverClaim(); // never past the reserve, whatever the root sums to
        claimedBy[msg.sender] = done;
        claimedTotal = total;
        SafeTransferLib.safeTransferFrom(imdstr, msg.sender, address(this), amount);
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Pays the ETH here (beyond what is set aside for $IMD) to the payees, pro rata; the burn executor's share
    ///         is set aside for {burnImd} instead. After the launch only. A payee that refuses its share leaves it here
    ///         for the next split, booked to it ({owed}): it is offered to that payee again, never divided among the
    ///         others.
    function split() public nonReentrant returns (uint256 amount) {
        if (token == address(0)) revert NotLaunched();
        amount = address(this).balance - imdBucket - owedTotal - perpFeesOwed;
        if (amount == 0 && owedTotal == 0) return 0;
        (address[] memory to, uint16[] memory bps) = payees();
        for (uint256 i; i < to.length; ++i) {
            uint256 part = (amount * bps[i]) / 10_000;
            if (to[i] == imdBurn) {
                imdBucket += part;
                continue;
            }
            uint256 due = owed[to[i]];
            uint256 pay = part + due;
            if (pay == 0) continue;
            (bool ok,) = to[i].call{value: pay}("");
            if (ok) {
                if (due != 0) {
                    owedTotal -= due;
                    owed[to[i]] = 0;
                }
            } else {
                owedTotal += part;
                owed[to[i]] = pay;
                emit PayFailed(to[i], pay);
            }
        }
        emit Split(amount);
    }

    /// @notice Buys $IMD with what is set aside for its burn, at most {IMD_BUY_MAX} a block timestamp (one call a
    ///         timestamp: a transaction that loops it spends no more than one call), and sends it to IMD's burn
    ///         executor (anyone can then bridge it to Base, where it is destroyed). Anyone. The bucket is debited by
    ///         what the pool took, which is less than offered only when its liquidity runs out.
    /// @param minImd the least $IMD the buy may return
    function burnImd(uint256 minImd) external nonReentrant returns (uint256 imd) {
        if (lastImdBuy == block.timestamp) revert BoughtThisBlock();
        lastImdBuy = block.timestamp;
        uint256 spend = imdBucket < IMD_BUY_MAX ? imdBucket : IMD_BUY_MAX;
        if (spend == 0) revert NoEth();
        uint256 ethIn;
        (imd, ethIn) = abi.decode(poolManager.unlock(abi.encode(uint8(1), spend)), (uint256, uint256));
        if (imd < minImd) revert Short(imd);
        imdBucket -= ethIn;
        SafeTransferLib.safeTransfer(IMD, imdBurn, imd);
        imdBurned += imd;
        emit ImdBurned(ethIn, imd);
    }

    function imdPoolKey() public view returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), imdPoolFee, imdPoolTickSpacing, IHooks(imdPoolHooks));
    }

    /// @notice Collects the pool's fees (its IMD6900 burned, its ETH here) and splits the ETH
    function harvest() external returns (uint256) {
        pool.collect();
        return split();
    }

    /*                            POOL MANAGER                              */

    /// @dev A buy, ETH in, the other side out, as far as the price goes: the opening buy (0) on the coin's pool, or
    ///      $IMD's burn (1) on its pool; or (2) the timelock's sale of held coins on the coin's pool
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint8 what, uint256 spend) = abi.decode(data, (uint8, uint256));
        if (what == 2) {
            // fee-free: the locked pool hands each swap's fee (paid in the coin) straight back, and what comes back is
            // sold again, three rounds (what is left, 4.44% cubed of it, stays held)
            PoolKey memory k = pool.poolKey();
            uint256 left = spend;
            uint256 ethOut;
            uint256 sold;
            for (uint256 i; i < 3 && left != 0; ++i) {
                pool.feeCheckpoint();
                BalanceDelta s = poolManager.swap(k, SwapParams(false, -int256(left), TickMath.MAX_SQRT_PRICE - 1), "");
                (, uint256 back) = pool.feeRefund(address(this));
                uint256 paid = uint256(uint128(-s.amount1()));
                ethOut += uint256(uint128(s.amount0()));
                poolManager.sync(k.currency1);
                SafeTransferLib.safeTransfer(token, address(poolManager), paid);
                poolManager.settle();
                sold += paid - back;
                if (paid < left) break; // the pool took what it could
                left = back;
            }
            poolManager.take(k.currency0, address(this), ethOut);
            return abi.encode(ethOut, sold);
        }
        PoolKey memory key = what == 0 ? pool.poolKey() : imdPoolKey();
        BalanceDelta d = poolManager.swap(key, SwapParams(true, -int256(spend), TickMath.MIN_SQRT_PRICE + 1), "");
        uint256 ethIn = uint256(uint128(-d.amount0()));
        uint256 out = uint256(uint128(d.amount1()));
        poolManager.settle{value: ethIn}();
        poolManager.take(key.currency1, address(this), out);
        return abi.encode(out, ethIn);
    }

    /*                              INTERNAL                                */

    /// @dev Drops what `payee` was owed: the next split divides it among the payees of the day
    function _cancelOwed(address payee) internal {
        uint256 due = owed[payee];
        if (due == 0) return;
        owedTotal -= due;
        owed[payee] = 0;
        emit OwedCancelled(payee, due);
    }

    function _hookInitCode() internal view returns (bytes memory) {
        return abi.encodePacked(type(IMD6900Hook).creationCode, abi.encode(poolManager, address(pool), timelock));
    }

    /// @dev A Merkle proof over sorted pairs
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }
}
