// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMD6900} from "../src/IMD6900.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {MockImdstr, Trader, RefundingEngine, IERC20} from "./IMD6900RobinhoodLaunch.t.sol";

/// The inputs the happy path did not consider: zero, one wei, the whole supply, the maximum, the same call twice,
/// a caller who is not who the code assumed; and the arithmetic fuzzed at its edges.
contract EdgesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    address constant R = address(0x2E7);
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant BUY = 2.81 ether;
    uint256 constant OPEN_MC = 19.18 ether;
    address constant A = address(0xA);
    uint256 constant AA = 40_000_000 ether;

    IPoolManager PM;
    IMD6900RobinhoodLaunch L;
    IMD6900Hook hook;
    IMD6900LockedPool pool;
    MockImdstr imdstr;
    Trader trader;
    bytes32 SALT;

    function setUp() public {
        PM = IPoolManager(vm.deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        imdstr = new MockImdstr();
        L = _newLaunch();
        hook = L.createHook(HookSalt.mine(L));
        pool = L.pool();
        SALT = CoinSalt.mine(L);
        imdstr.mint(A, AA);
        trader = new Trader(PM);
        vm.deal(address(trader), 100 ether);
    }

    /*                           FUZZ: THE ARITHMETIC                        */

    /// The opening at any price and buy size: the whole supply goes in, every wei is spent, what the pool can't
    /// take and what the buy landed are held here, and nothing is lost in the rounding
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_TheOpeningAtAnyPriceAndSize(uint256 mc, uint256 buy) public {
        mc = bound(mc, 0.1 ether, 100_000 ether);
        buy = bound(buy, 1 gwei, 500 ether);
        vm.deal(OWNER, buy);
        address expected = L.tokenAddress(SALT);
        vm.prank(OWNER);
        (address t, uint256 bought) = L.launch{value: buy}(SALT, expected, _sqrtPrice(mc), 0, address(L));
        assertEq(address(L).balance, 0, "every wei spent");
        assertEq(address(PM).balance, buy, "all of it in the pool");
        assertLt(bought, SUPPLY);
        assertGe(L.excessHeld(), bought, "the buy's coins (and the opening's dust) are held for the timelock");
        assertEq(IERC20(t).balanceOf(address(L)), L.excessHeld());
        assertEq(IERC20(t).balanceOf(address(PM)) + L.excessHeld(), SUPPLY, "nothing lost");
        assertEq(IERC20(t).totalSupply(), SUPPLY);
        (uint160 sq,, uint128 inPool) = pool.state();
        // a buy (ETH in) moves v4's price down from the opening tick into the coin-only range
        assertLe(sq, TickMath.getSqrtPriceAtTick(pool.upperTick()), "the buy moved the price into the range");
        assertGt(sq, TickMath.getSqrtPriceAtTick(pool.LOWER_TICK()), "and not out of it");
        assertEq(inPool, pool.liquidity());
        assertGt(inPool, 0);
    }

    /// The claims' reserve must be covered by the buy, whatever the buy: either it lands enough or the launch
    /// refuses, never a reserve the launch can't pay
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_TheReserveIsCoveredOrTheLaunchRefuses(uint256 buy, uint256 total) public {
        buy = bound(buy, 1 gwei, 50 ether);
        total = bound(total, 1, 500_000_000 ether);
        vm.prank(OWNER);
        L.setClaims(_leaf(A, total), total, block.timestamp + 100 days);
        vm.deal(OWNER, buy);
        address expected = L.tokenAddress(SALT);
        vm.prank(OWNER);
        try L.launch{value: buy}(SALT, expected, _sqrtPrice(OPEN_MC), 0, address(L)) returns (
            address t, uint256 bought
        ) {
            assertGe(bought, total, "launched short of the reserve");
            assertGe(IERC20(t).balanceOf(address(L)), L.claimReserve() + L.excessHeld());
        } catch (bytes memory err) {
            assertEq(bytes4(err), IMD6900RobinhoodLaunch.Short.selector, "refused for another reason");
            assertEq(L.token(), address(0), "nothing launched");
        }
    }

    /// A claim in any number of parts never exceeds the snapshot, and the IMDSTR taken equals the coins given
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_ClaimsInParts(uint256 x, uint256 y) public {
        (address t,) = _launchWithClaims();
        x = bound(x, 1, AA);
        y = bound(y, 0, AA - x);
        bytes32[] memory p = new bytes32[](0);
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        L.claim(x, AA, p);
        if (y != 0) L.claim(y, AA, p);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(AA - x - y + 1, AA, p);
        if (x + y < AA) L.claim(AA - x - y, AA, p); // the rest, to the wei
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(A), AA);
        assertEq(imdstr.balanceOf(A), 0);
        assertEq(imdstr.balanceOf(address(L)), AA);
        assertEq(L.claimedTotal(), AA);
        assertEq(L.claimReserve(), 0);
        t;
    }

    /// The split at any amount and any share: the payees get their shares rounded down, the $IMD share is set
    /// aside, and at most the rounding's wei stays unassigned
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_TheSplitConservesEth(uint256 amount, uint16 potBps) public {
        _launch();
        amount = bound(amount, 1, 1_000 ether);
        potBps = uint16(bound(potBps, 0, 10_000));
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0], to[1], bps[1]) = (POT, potBps, L.IMD_BURN(), 10_000 - potBps);
        vm.prank(TL);
        L.setPayees(to, bps);
        vm.deal(address(L), amount);
        uint256 potBefore = POT.balance;
        L.split();
        uint256 toPot = POT.balance - potBefore;
        assertEq(toPot, amount * potBps / 10_000, "the pot's share, rounded down");
        assertEq(L.imdBucket(), amount * (10_000 - potBps) / 10_000, "the $IMD share, set aside");
        assertLe(amount - toPot - L.imdBucket(), 1, "at most a wei of rounding stays");
        assertEq(address(L).balance, amount - toPot);
        assertEq(L.owedTotal(), 0);
    }

    /// A move to any lower fee keeps the price and the liquidity (to the wei of rounding), and the new fee is what
    /// the next trade pays
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_LowerFeeToAnyLowerFee(uint24 newFee, uint256 trade) public {
        _launch();
        newFee = uint24(bound(newFee, 0, 44_399));
        trade = bound(trade, 0.001 ether, 20 ether);
        trader.swap(pool.poolKey(), true, -int256(trade));
        (uint160 p0,,) = pool.state();
        uint128 l0 = pool.liquidity();
        vm.prank(TL);
        uint128 l1 = pool.lowerFee(newFee);
        assertEq(pool.fee(), newFee);
        (uint160 p1,, uint128 inPool) = pool.state();
        assertEq(p1, p0, "same price");
        assertEq(inPool, l1);
        assertLe(l1, l0);
        assertGe(l1, l0 - l0 / 1e9, "all the liquidity, to the wei of rounding");
        assertEq(address(pool).balance, 0, "nothing stays in the locked pool");
        assertEq(IERC20(L.token()).balanceOf(address(pool)), 0);
        pool.collect(); // the move paid the old pool's fees out already: nothing more
        trader.swap(pool.poolKey(), true, -1 ether);
        (uint256 eth,) = pool.collect();
        assertApproxEqAbs(eth, uint256(1 ether) * newFee / 1_000_000, 1e6, "the new fee, on the next trade");
    }

    /// The refund pair hands back exactly the refunded caller's own fee, for a buy of any size
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_TheRefundIsExactlyTheSwapsFee(uint256 eth) public {
        _launch();
        eth = bound(eth, 0.0001 ether, 50 ether);
        pool.collect(); // the opening buy's fee out of the way
        RefundingEngine engine = new RefundingEngine(PM, pool);
        vm.deal(address(engine), eth);
        vm.prank(TL);
        hook.setPerpEngine(address(engine));
        (uint256 r0,) = engine.swap(pool.poolKey(), true, -int256(eth));
        assertApproxEqAbs(r0, eth * 444 / 10_000, 2, "the 4.44% back, to the wei of rounding");
        assertEq(address(engine).balance, r0, "it paid the whole amount and got the fee back");
        (uint256 left,) = pool.collect();
        assertLe(left, 2, "nothing of the engine's fee reaches the split");
    }

    /*                        THE FAILURE PATHS, PINNED                      */

    function test_PayeesAreValidated() public {
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0], to[1], bps[1]) = (POT, 9_000, R, 999); // sum 9,999
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        bps[1] = 1_001; // sum 10,001
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        (bps[1], to[1]) = (1_000, address(0)); // a zero payee
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(new address[](0), new uint16[](0)); // nobody
        uint16[] memory one = new uint16[](1);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, one); // lengths differ
        address[] memory nine = new address[](9);
        uint16[] memory nineBps = new uint16[](9);
        for (uint256 i; i < 9; ++i) {
            (nine[i], nineBps[i]) = (address(uint160(i + 1)), i == 0 ? 2_000 : 1_000);
        }
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(nine, nineBps); // more than MAX_PAYEES
        // exactly eight, summing to 10,000, is fine; the same payee twice is allowed (its shares add up)
        address[] memory eight = new address[](8);
        uint16[] memory eightBps = new uint16[](8);
        for (uint256 i; i < 8; ++i) {
            (eight[i], eightBps[i]) = (i < 4 ? POT : R, i == 0 ? 3_000 : 1_000);
        }
        vm.prank(TL);
        L.setPayees(eight, eightBps);
        (address[] memory got, uint16[] memory gotBps) = L.payees();
        assertEq(got.length, 8);
        assertEq(gotBps[0], 3_000);
        _launch();
        vm.deal(address(L), 1 ether);
        L.split();
        assertEq(POT.balance, 0.6 ether, "30% + 10% x 3");
        assertEq(R.balance, 0.4 ether);
    }

    function test_ClaimsCantBeHalfSet() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        L.setClaims(bytes32(0), 1, block.timestamp + 100 days); // a total with no root
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        L.setClaims(bytes32(uint256(1)), 0, block.timestamp + 100 days); // a root with no total
        vm.prank(A);
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.setClaims(bytes32(uint256(1)), 1, block.timestamp + 100 days);
        vm.prank(OWNER);
        L.setClaims(bytes32(0), 0, 0); // no claims at all: fine, and the launch needs no window
        _launch();
        assertEq(L.claimReserve(), 0);
        vm.prank(OWNER);
        L.releaseUnclaimed(address(0)); // nothing to release, but the flag closes claims
        assertTrue(L.unclaimedReleased());
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.releaseUnclaimed(address(0));
    }

    function test_ClaimZeroAndBeforeTheLaunch() public {
        bytes32[] memory p = new bytes32[](0);
        vm.prank(OWNER);
        L.setClaims(_leaf(A, AA), AA, block.timestamp + 100 days);
        vm.prank(A);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        L.claim(1, AA, p);
        _launch();
        vm.prank(A);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.claim(0, AA, p);
        vm.prank(A); // no approval: the IMDSTR transfer fails, nothing is booked
        vm.expectRevert();
        L.claim(1, AA, p);
        assertEq(L.claimedBy(A), 0);
        assertEq(L.claimedTotal(), 0);
        IMD6900RobinhoodLaunch fresh = _newLaunch();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        fresh.releaseUnclaimed(address(0));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        fresh.endClaims();
    }

    function test_ZeroAmountsAreRefused() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.withdrawEth(OWNER, 0); // nothing here yet
        vm.deal(address(L), 1 ether);
        vm.prank(OWNER);
        vm.expectRevert();
        L.withdrawEth(OWNER, 2 ether); // more than held
        vm.prank(OWNER);
        L.withdrawEth(OWNER, 1 wei);
        assertEq(OWNER.balance, 1 wei);
        vm.prank(OWNER);
        L.withdrawEth(OWNER, 0); // the rest
        assertEq(OWNER.balance, 1 ether);
        assertEq(address(L).balance, 0);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseImdstr(0, OWNER); // none collected
        imdstr.mint(address(L), 10);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseImdstr(11, OWNER); // more than held
        vm.prank(A);
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.releaseImdstr(0, A);
        vm.prank(OWNER);
        L.releaseImdstr(0, OWNER);
        assertEq(imdstr.balanceOf(OWNER), 10);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.sellHeld(0, 0, TL); // nothing held before the launch
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseExcess(0, TL);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.recoverEth(TL, 0); // nothing left to recover
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.burnImd(0); // nothing set aside
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        L.split();
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        L.harvest();
    }

    function test_TheLaunchNeedsEth() public {
        address expected = L.tokenAddress(SALT);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.launch(SALT, expected, _sqrtPrice(OPEN_MC), 0, address(0));
        assertEq(L.token(), address(0), "nothing launched, the salt is still free");
        // the opening buy's floor holds
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        vm.expectPartialRevert(IMD6900RobinhoodLaunch.Short.selector);
        L.launch{value: BUY}(SALT, expected, _sqrtPrice(OPEN_MC), SUPPLY, address(0));
        // the opening price must sit above the lowest tick
        vm.prank(OWNER);
        vm.expectRevert(IMD6900LockedPool.BadPrice.selector);
        L.launch{value: BUY}(SALT, expected, TickMath.MIN_SQRT_PRICE, 0, address(0));
        uint160 lowest = TickMath.getSqrtPriceAtTick(pool.LOWER_TICK());
        vm.prank(OWNER);
        vm.expectRevert(IMD6900LockedPool.BadPrice.selector);
        L.launch{value: BUY}(SALT, expected, lowest, 0, address(0));
        assertEq(L.token(), address(0));
    }

    function test_TheTimelocksSettersRefuseNobody() public {
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setImdBurn(address(0));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPerpFeeTo(address(L)); // not itself: the perps' fees would pool here
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPerpFeeTo(address(0));
    }

    function test_OnlyTheLauncherRunsTheLockedPool() public {
        IMD6900RobinhoodLaunch l = _newLaunch();
        IMD6900LockedPool p = l.pool();
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        p.setHook(address(this));
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        p.open(address(1), 1, 1);
        vm.prank(address(l)); // the launcher itself can't open before the hook exists
        vm.expectRevert(IMD6900LockedPool.NoHook.selector);
        p.open(address(1), 1, 1);
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        p.collect();
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        p.lowerFee(0);
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        p.createPerps("", "");
        vm.expectRevert(IMD6900LockedPool.OnlyPoolManager.selector);
        p.unlockCallback(abi.encode(uint8(1), uint128(0)));
        vm.expectRevert(IMD6900RobinhoodLaunch.OnlyPoolManager.selector);
        l.unlockCallback(abi.encode(uint8(0), uint256(1)));
        // once open, it can't open again, even for the launcher
        _launch();
        vm.prank(address(L));
        vm.expectRevert(IMD6900LockedPool.AlreadyOpen.selector);
        pool.open(address(1), 1, 1);
        vm.prank(address(L));
        vm.expectRevert(IMD6900LockedPool.HookAlreadySet.selector);
        pool.setHook(address(1));
    }

    function test_TheHookServesOnlyItsPool() public {
        _launch();
        // nobody else initializes a pool on this hook, even a matching key
        PoolKey memory k = pool.poolKey();
        k.fee = 3_000;
        vm.expectRevert();
        PM.initialize(k, TickMath.getSqrtPriceAtTick(0));
        // another token on the hook: refused too
        PoolKey memory other =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imdstr)), 44_400, 60, IHooks(address(hook)));
        vm.expectRevert();
        PM.initialize(other, TickMath.getSqrtPriceAtTick(0));
        // the callbacks come only from the PoolManager
        vm.expectRevert();
        hook.beforeSwap(address(this), k, SwapParams(true, -1, 0), "");
        vm.expectRevert();
        hook.beforeInitialize(address(pool), k, 1);
        vm.expectRevert();
        hook.beforeAddLiquidity(address(pool), k, ModifyLiquidityParams(0, 0, 0, 0), "");
        // and only the locked pool wires the first engine
        vm.expectRevert(IMD6900Hook.OnlyPool.selector);
        hook.initPerpEngine(address(1));
        vm.prank(address(pool));
        hook.initPerpEngine(address(1));
        vm.prank(address(pool));
        vm.expectRevert(IMD6900Hook.EngineSet.selector);
        hook.initPerpEngine(address(2));
        assertTrue(hook.perpRefunded());
    }

    function test_SweepFailOpenIsTheTimelocksOnly() public {
        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setSweepFailOpen(true);
        vm.prank(TL);
        hook.setSweepFailOpen(true);
        assertTrue(hook.sweepFailOpen());
        // with an engine that can't sweep at all, trades revert unless fail-open is set
        _launch();
        vm.prank(TL);
        hook.setPerpEngine(address(0xDEAD)); // no code: the sweep call "succeeds" with no data
        PoolKey memory k = pool.poolKey();
        trader.swap(k, true, -0.1 ether); // fail-open: trades
        vm.prank(TL);
        hook.setSweepFailOpen(false);
        vm.expectRevert();
        trader.swap(k, true, -0.1 ether); // fail-closed: SweepUnavailable
    }

    function test_TheWholeExcessSoldInOneGo() public {
        (address t,) = _launchHeld();
        uint256 held = L.excessHeld();
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.sellHeld(held + 1, 0, R);
        vm.prank(TL);
        uint256 eth = L.sellHeld(held, 0, R);
        assertEq(R.balance, eth);
        assertGt(eth, BUY * 9 / 10, "nearly all of the buy's ETH back, the sale being fee-free");
        assertEq(IERC20(t).balanceOf(address(L)), L.excessHeld(), "what the last round's refund left, still held");
    }

    function test_RecoverEthAllOfItAndMoreThanHeld() public {
        _launch();
        vm.deal(address(L), 1 ether);
        L.split();
        assertEq(L.imdBucket(), 0.1 ether);
        vm.prank(TL);
        vm.expectRevert();
        L.recoverEth(TL, 1 ether); // more than what is left after the split
        vm.prank(TL);
        L.recoverEth(TL, 0); // all of it: the bucket goes with it
        assertEq(TL.balance, 0.1 ether);
        assertEq(L.imdBucket(), 0);
        assertEq(address(L).balance, 0);
    }

    /*                               HELPERS                                */

    function _launch() internal returns (address t, uint256 bought) {
        vm.deal(OWNER, BUY);
        address expected = L.tokenAddress(SALT);
        vm.prank(OWNER);
        (t, bought) = L.launch{value: BUY}(SALT, expected, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    function _launchHeld() internal returns (address t, uint256 bought) {
        vm.deal(OWNER, BUY);
        address expected = L.tokenAddress(SALT);
        vm.prank(OWNER);
        (t, bought) = L.launch{value: BUY}(SALT, expected, _sqrtPrice(OPEN_MC), 0, address(L));
    }

    function _launchWithClaims() internal returns (address t, uint256 bought) {
        vm.prank(OWNER);
        L.setClaims(_leaf(A, AA), AA, block.timestamp + 100 days); // one leaf: the root is the leaf
        return _launch();
    }

    function _sqrtPrice(uint256 mc) internal pure returns (uint160) {
        return uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, mc)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _newLaunch() internal returns (IMD6900RobinhoodLaunch) {
        return IMD6900RobinhoodLaunch(
            payable(vm.deployCode(
                    "IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch", abi.encode(OWNER, PM, address(imdstr), TL)
                ))
        );
    }
}
