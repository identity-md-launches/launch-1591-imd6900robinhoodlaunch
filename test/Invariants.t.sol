// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {PerpEngine} from "../src/perps/PerpEngine.sol";
import {PerpVault} from "../src/perps/PerpVault.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {MockImdstr, Trader, Refuser, LiquidityAdder} from "./IMD6900RobinhoodLaunch.t.sol";

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Everything the launched system holds, driven in random order with bounded inputs: traders buying and
///      selling through the PoolManager, the three snapshot holders claiming, anyone collecting and splitting,
///      the timelock selling the held coins back, ending the claims, lowering the fee, resetting the payees and
///      recovering ETH, the owner releasing the unclaimed rest, and the perps: longs, shorts, closes, liquidations,
///      the vault's stakes and the fee flush. Every call that is expected to fail for a bounded input is caught, so
///      the sequence goes on; what must never fail is asserted in the invariants below.
contract LaunchHandler is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable PM;
    IMD6900RobinhoodLaunch immutable L;
    IMD6900Hook immutable hook;
    IMD6900LockedPool immutable pool;
    PerpEngine immutable engine;
    PerpVault immutable vault;
    MockImdstr immutable imdstr;
    address immutable coin;
    address immutable OWNER;
    address immutable TL;
    address immutable REFUSER;
    address immutable PAYEE;

    Trader[] public traders;
    address[3] public claimants;
    uint256[3] public allowances;
    bytes32[][3] proofs;
    uint256[] public openIds; // what this handler opened (closed ones are pruned lazily)

    // ghosts
    uint256 public ghostClaimed; // the coins the claims handed out
    uint256 public ghostImdstrIn; // the IMDSTR the claims took in
    uint256 public ghostFeeLowered; // how many times the fee moved
    uint256 public ghostOpens;
    uint256 public ghostOpenRefusals; // opens the engine's caps refused
    uint256 public ghostCloses;
    uint256 public ghostLiquidations;
    uint256 public ghostSweepRefusals; // trades the pre-trade sweep refused (too large / starved)
    uint256 public ghostSold; // coins the timelock sold back
    uint256 public ghostEthRecovered;
    uint256 public ghostEthToPayees; // what split() paid to payees who accept, plus what burnImd spent
    uint256 public ghostPayeeRefused; // the refuser's share, booked as owed
    bool public ghostClaimsEnded;
    uint24 public ghostLastFee = 44_400;
    uint256 public ghostImdBuys;
    uint256 public ghostBucketIn; // what split() set aside for the $IMD burn
    uint256 public ghostBucketOut; // what burnImd took out of it
    uint256 public ghostPerpFeesForwarded; // perps fees that reached perpFeeTo
    uint256 public ghostPerpFeesBooked; // perps fees perpFeeTo refused, booked for it (counted once each)

    constructor(
        IPoolManager pm,
        IMD6900RobinhoodLaunch l,
        PerpEngine e,
        PerpVault v,
        MockImdstr s,
        address owner_,
        address tl,
        address[3] memory cs,
        uint256[3] memory as_,
        bytes32[][3] memory ps,
        address refuser,
        address payee
    ) {
        (PM, L, engine, vault, imdstr, OWNER, TL) = (pm, l, e, v, s, owner_, tl);
        hook = l.hook();
        pool = l.pool();
        coin = l.token();
        for (uint256 i; i < 3; ++i) {
            claimants[i] = cs[i];
            allowances[i] = as_[i];
            proofs[i] = ps[i];
        }
        (REFUSER, PAYEE) = (refuser, payee);
        for (uint256 i; i < 4; ++i) {
            Trader t = new Trader(pm);
            traders.push(t);
        }
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }

    /*                               TRADERS                                */

    function buy(uint256 who, uint256 eth) external {
        Trader t = traders[bound(who, 0, traders.length - 1)];
        eth = bound(eth, 0.0001 ether, 8 ether);
        vm.deal(address(t), address(t).balance + eth);
        try t.swap(pool.poolKey(), true, -int256(eth)) {}
        catch (bytes memory err) {
            _countSweep(err);
        }
    }

    function sell(uint256 who, uint256 frac) external {
        Trader t = traders[bound(who, 0, traders.length - 1)];
        uint256 held = IERC20View(coin).balanceOf(address(t));
        if (held == 0) return;
        uint256 amount = bound(frac, 1, held);
        try t.swap(pool.poolKey(), false, -int256(amount)) {}
        catch (bytes memory err) {
            _countSweep(err);
        }
    }

    function collect() external {
        pool.collect();
    }

    function split() external {
        _split();
    }

    function harvest() external {
        pool.collect();
        _split();
    }

    function burnImd() external {
        uint256 bucket = L.imdBucket();
        if (bucket == 0) return;
        uint256 spend = bucket < L.IMD_BUY_MAX() ? bucket : L.IMD_BUY_MAX();
        uint256 before = address(L).balance;
        try L.burnImd(0) {
            // the bucket is debited by what the pool took, never more than offered, and that is what left the launch
            uint256 took = bucket - L.imdBucket();
            assertLe(took, spend, "burnImd spent more than its cap");
            assertEq(before - address(L).balance, took, "the bucket and the balance disagree on the buy");
            ghostEthToPayees += took;
            ghostBucketOut += took;
            ++ghostImdBuys;
            // one buy a timestamp: the same call again in this block is refused, whatever is left in the bucket
            vm.expectRevert(IMD6900RobinhoodLaunch.BoughtThisBlock.selector);
            L.burnImd(0);
        } catch (bytes memory err) {
            // only the gate: a bucket this handler found non-empty is otherwise always spendable
            assertEq(bytes4(err), IMD6900RobinhoodLaunch.BoughtThisBlock.selector, "burnImd failed for another reason");
            assertEq(L.lastImdBuy(), block.timestamp, "BoughtThisBlock without a buy this timestamp");
        }
    }

    /*                        THE PERPS' FEE FORWARDING                      */

    /// The engine's fees reach {perpFeeTo}; what it refuses is booked and never lost to the split
    function flushFees() external {
        uint256 owed = engine.feesOwed();
        if (owed == 0) return;
        uint256 bookedBefore = L.perpFeesOwed();
        uint256 toBefore = L.perpFeeTo().balance;
        uint256 flushed = engine.flushFees();
        assertEq(flushed, owed);
        _checkForwarding(flushed, bookedBefore, toBefore);
    }

    /// Anyone may pay perps fees in (as the engine does); the same forwarding, the same booking
    function addPerpFees(uint256 eth) external {
        eth = bound(eth, 0, 0.5 ether);
        address a = address(traders[0]);
        vm.deal(a, a.balance + eth);
        uint256 bookedBefore = L.perpFeesOwed();
        uint256 toBefore = L.perpFeeTo().balance;
        vm.prank(a);
        L.addPerpFees{value: eth}();
        _checkForwarding(eth, bookedBefore, toBefore);
    }

    /// The timelock points the perps' fees at the refuser, a payee or the pot; nobody else can
    function setPerpFeeTo(uint256 pick) external {
        uint256 which = bound(pick, 0, 2);
        address to = which == 0 ? REFUSER : which == 1 ? PAYEE : L.POT_BRIDGE();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setPerpFeeTo(to);
        vm.prank(TL);
        L.setPerpFeeTo(to);
    }

    function refuserOpens(bool open) external {
        Refuser(payable(REFUSER)).setOpen(open);
    }

    /// Nobody renounces the launch: not its owner, not the timelock
    function renounce() external {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoRenounce.selector);
        L.renounceOwnership();
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoRenounce.selector);
        L.renounceOwnership();
    }

    /*                               CLAIMS                                 */

    function claim(uint256 who, uint256 amount) external {
        uint256 i = bound(who, 0, 2);
        address a = claimants[i];
        uint256 left = allowances[i] - L.claimedBy(a);
        if (left == 0 || L.unclaimedReleased()) return;
        amount = bound(amount, 1, left);
        vm.startPrank(a);
        imdstr.approve(address(L), amount);
        L.claim(amount, allowances[i], proofs[i]);
        vm.stopPrank();
        ghostClaimed += amount;
        ghostImdstrIn += amount;
    }

    /// A claim past the snapshot balance, and one with a wrong allowance: both refused
    function overClaim(uint256 who) external {
        uint256 i = bound(who, 0, 2);
        address a = claimants[i];
        if (L.unclaimedReleased()) return;
        uint256 left = allowances[i] - L.claimedBy(a);
        vm.startPrank(a);
        imdstr.approve(address(L), type(uint256).max);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(left + 1, allowances[i], proofs[i]);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, allowances[i] + 1, proofs[i]);
        vm.stopPrank();
    }

    function releaseUnclaimed(bool burn) external {
        if (block.timestamp < L.claimDeadline() || L.unclaimedReleased()) return;
        vm.prank(OWNER);
        L.releaseUnclaimed(burn ? address(0) : PAYEE);
        ghostClaimsEnded = true;
    }

    /*                             THE TIMELOCK                             */

    function sellHeld(uint256 frac) external {
        uint256 held = L.excessHeld();
        if (held == 0) return;
        uint256 amount = bound(frac, 1, held);
        uint256 before = L.excessHeld();
        vm.prank(TL);
        try L.sellHeld(amount, 0, PAYEE) {
            ghostSold += before - L.excessHeld();
        } catch (bytes memory err) {
            _countSweep(err);
        }
    }

    function endClaims() external {
        if (L.unclaimedReleased()) return;
        vm.prank(TL);
        L.endClaims();
        ghostClaimsEnded = true;
    }

    function releaseExcess(uint256 frac, bool burn) external {
        uint256 held = L.excessHeld();
        if (held == 0) return;
        uint256 amount = bound(frac, 1, held);
        vm.prank(TL);
        L.releaseExcess(amount, burn ? address(0) : PAYEE);
    }

    function lowerFee(uint24 newFee) external {
        uint24 cur = pool.fee();
        if (cur == 0) return;
        newFee = uint24(bound(newFee, 0, cur - 1));
        // never up, never the same
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        pool.lowerFee(cur);
        vm.prank(TL);
        try pool.lowerFee(newFee) {
            ghostLastFee = newFee;
            ++ghostFeeLowered;
        } catch (bytes memory err) {
            // only while the engine has positions open
            assertEq(bytes4(err), IMD6900LockedPool.PerpsOpen.selector, "lowerFee failed for another reason");
            assertGt(engine.openCount(), 0, "PerpsOpen with nothing open");
        }
    }

    function raiseFeeRefused(uint24 higher) external {
        uint24 cur = pool.fee();
        higher = uint24(bound(higher, cur, 1_000_000));
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        pool.lowerFee(higher);
    }

    function setPayees(uint256 pick, uint16 potShare) external {
        uint256 which = bound(pick, 0, 2);
        address[] memory to;
        uint16[] memory bps;
        if (which == 0) {
            (to, bps) = (new address[](2), new uint16[](2));
            potShare = uint16(bound(potShare, 0, 10_000));
            (to[0], bps[0], to[1], bps[1]) = (L.POT_BRIDGE(), potShare, L.imdBurn(), 10_000 - potShare);
        } else if (which == 1) {
            (to, bps) = (new address[](3), new uint16[](3));
            potShare = uint16(bound(potShare, 0, 5_000));
            (to[0], bps[0], to[1], bps[1], to[2], bps[2]) =
            (REFUSER, potShare, PAYEE, 5_000, L.imdBurn(), 5_000 - potShare);
        } else {
            (to, bps) = (new address[](1), new uint16[](1));
            (to[0], bps[0]) = (PAYEE, 10_000);
        }
        vm.prank(TL);
        L.setPayees(to, bps);
    }

    function recoverEth(uint256 frac) external {
        uint256 bal = address(L).balance;
        if (bal == 0) return;
        uint256 amount = bound(frac, 1, bal);
        vm.prank(TL);
        L.recoverEth(PAYEE, amount);
        ghostEthRecovered += amount;
    }

    /*                               THE PERPS                              */

    function openLong(uint256 who, uint256 eth, uint8 lev) external {
        _open(true, who, eth, lev);
    }

    function openShort(uint256 who, uint256 eth, uint8 lev) external {
        _open(false, who, eth, lev);
    }

    function close(uint256 pick) external {
        uint256 n = _prune();
        if (n == 0) return;
        uint256 id = openIds[bound(pick, 0, n - 1)];
        (address trader,,,,,,,) = engine.positions(id);
        vm.prank(trader);
        try engine.close(id, 0) {
            ++ghostCloses;
        } catch (bytes memory err) {
            _countSweep(err);
        }
    }

    function liquidate(uint256 pick) external {
        uint256 n = _prune();
        if (n == 0) return;
        uint256 id = openIds[bound(pick, 0, n - 1)];
        bool liq = engine.isLiquidatable(id);
        try engine.liquidate(id) {
            assertTrue(liq, "liquidated a healthy position");
            ++ghostLiquidations;
        } catch (bytes memory err) {
            if (bytes4(err) == PerpEngine.Healthy.selector) assertFalse(liq, "refused a liquidatable position");
        }
    }

    function stakeEth(uint256 who, uint256 eth) external {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        eth = bound(eth, 0.01 ether, 20 ether);
        vm.deal(a, a.balance + eth);
        vm.prank(a);
        try vault.depositEth{value: eth}() {} catch {}
    }

    function unstakeEth(uint256 who, uint256 frac) external {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        uint256 shares = vault.ethShareOf(a);
        if (shares == 0) return;
        vm.prank(a);
        try vault.withdrawEth(bound(frac, 1, shares)) {} catch {}
    }

    function claimPendingEth(uint256 who) external {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        if (vault.pendingEthOf(a) == 0) return;
        vm.prank(a);
        try vault.claimPendingEth() {} catch {}
    }

    function stakeToken(uint256 who, uint256 frac) external {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        uint256 held = IERC20View(coin).balanceOf(a);
        if (held == 0) return;
        uint256 amount = bound(frac, 1, held);
        vm.startPrank(a);
        IERC20View(coin).approve(address(vault), amount);
        try vault.depositToken(amount) {} catch {}
        vm.stopPrank();
    }

    function unstakeToken(uint256 who, uint256 frac) external {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        uint256 shares = vault.tokShareOf(a);
        if (shares == 0) return;
        vm.prank(a);
        try vault.withdrawToken(bound(frac, 1, shares)) {} catch {}
    }

    function claimPayout(uint256 who) external {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        if (engine.payoutOwed(a) == 0) return;
        vm.prank(a);
        engine.claimPayout();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
        engine.poke();
    }

    /*                               VIEWS                                  */

    function openPositions() external view returns (uint256[] memory) {
        return engine.openIds();
    }

    /// The sum of every short's ETH backing (collateral + proceeds), which the engine holds
    function shortBacking() external view returns (uint256 sum) {
        uint256[] memory ids = engine.openIds();
        for (uint256 i; i < ids.length; ++i) {
            (, bool isLong, uint128 collateral,, uint256 principal,,,) = engine.positions(ids[i]);
            if (!isLong) sum += uint256(collateral) + principal;
        }
    }

    /*                              INTERNAL                                */

    function _open(bool long, uint256 who, uint256 eth, uint8 lev) internal {
        address a = address(traders[bound(who, 0, traders.length - 1)]);
        lev = uint8(bound(lev, 2, 5));
        // a position's notional is capped at 3.5% of the pool's ETH depth: size the collateral under it (with the
        // 6.9% open fee on top), and sometimes over it, so the cap is exercised too
        uint256 maxNotional = engine.activeEthDepth() * engine.maxNotionalBps() / 10_000;
        uint256 maxEth = maxNotional / lev * 10_000 / (10_000 - engine.openFeeBps());
        uint256 hi = maxEth > 0.011 ether ? maxEth + maxEth / 10 : 0.011 ether;
        eth = bound(eth, 0.011 ether, hi);
        // the engine lends what the stakers put in: stake it first when there is nothing to lend
        if (long && engine.plv() < eth * lev) {
            address s = address(traders[0]);
            vm.deal(s, s.balance + eth * lev);
            vm.prank(s);
            try vault.depositEth{value: eth * lev}() {} catch {}
        } else if (!long && engine.plvToken() == 0) {
            Trader s = traders[0];
            vm.deal(address(s), address(s).balance + 0.5 ether);
            try s.swap(pool.poolKey(), true, -0.5 ether) {} catch {}
            uint256 held = IERC20View(coin).balanceOf(address(s));
            if (held != 0) {
                vm.startPrank(address(s));
                IERC20View(coin).approve(address(vault), held);
                try vault.depositToken(held) {} catch {}
                vm.stopPrank();
            }
        }
        vm.deal(a, a.balance + eth);
        vm.prank(a);
        if (long) {
            try engine.openLong{value: eth}(lev, 0) returns (uint256 id) {
                openIds.push(id);
                ++ghostOpens;
            } catch {
                ++ghostOpenRefusals;
            }
        } else {
            try engine.openShort{value: eth}(lev, 0) returns (uint256 id) {
                openIds.push(id);
                ++ghostOpens;
            } catch {
                ++ghostOpenRefusals;
            }
        }
    }

    function _prune() internal returns (uint256 n) {
        for (uint256 i; i < openIds.length;) {
            (address trader,,,,,,,) = engine.positions(openIds[i]);
            if (trader == address(0)) {
                openIds[i] = openIds[openIds.length - 1];
                openIds.pop();
            } else {
                ++i;
            }
        }
        return openIds.length;
    }

    function _split() internal {
        uint256 before = address(L).balance;
        uint256 owedBefore = L.owedTotal();
        uint256 bucketBefore = L.imdBucket();
        uint256 perpBooked = L.perpFeesOwed();
        L.split();
        uint256 paid = before - address(L).balance;
        ghostEthToPayees += paid;
        if (L.owedTotal() > owedBefore) ghostPayeeRefused += L.owedTotal() - owedBefore;
        if (L.imdBucket() > bucketBefore) ghostBucketIn += L.imdBucket() - bucketBefore;
        // the split never touches what the perps' destination is owed, nor pays it out to the payees
        assertEq(L.perpFeesOwed(), perpBooked, "split moved the perps' book");
        assertGe(address(L).balance, L.imdBucket() + L.owedTotal() + perpBooked, "split paid out the perps' book");
    }

    /// After a forwarding of `paid` new wei: either everything (the new and the booked) reached perpFeeTo and the
    /// book is clear, or the destination refused, nothing left the launch and the book grew by exactly `paid`
    function _checkForwarding(uint256 paid, uint256 bookedBefore, uint256 toBefore) internal {
        address to = L.perpFeeTo();
        uint256 booked = L.perpFeesOwed();
        if (paid + bookedBefore == 0) {
            assertEq(booked, 0, "booked out of nothing");
            return;
        }
        if (booked == 0) {
            assertEq(to.balance - toBefore, paid + bookedBefore, "perpFeeTo got less than the new and the booked");
            ghostPerpFeesForwarded += paid + bookedBefore;
        } else {
            assertEq(to, REFUSER, "a destination that accepts was booked");
            assertEq(to.balance, toBefore, "the refuser was paid");
            assertEq(booked, bookedBefore + paid, "the book is not the old book plus what came in");
            ghostPerpFeesBooked += paid;
        }
    }

    function _countSweep(bytes memory err) internal {
        bytes4 s = bytes4(err);
        if (s == IMD6900Hook.SweepTradeTooLarge.selector || s == IMD6900Hook.SweepGasStarved.selector) {
            ++ghostSweepRefusals;
        }
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract LaunchInvariantTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    address constant PAYEE = address(0x2E7);
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant BUY = 2.81 ether;
    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);
    uint256 constant AA = 40_000_000 ether;
    uint256 constant BB = 20_000_000 ether;
    uint256 constant CC = 3_935_747 ether;

    IPoolManager PM;
    IMD6900RobinhoodLaunch L;
    IMD6900Hook hook;
    IMD6900LockedPool pool;
    PerpEngine engine;
    PerpVault vault;
    MockImdstr imdstr;
    address coin;
    Refuser refuser;
    LaunchHandler handler;
    bytes32[] leaves;

    function setUp() public {
        PM = IPoolManager(vm.deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        imdstr = new MockImdstr();
        L = IMD6900RobinhoodLaunch(
            payable(vm.deployCode(
                    "IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch", abi.encode(OWNER, PM, address(imdstr), TL)
                ))
        );
        hook = L.createHook(HookSalt.mine(L));
        pool = L.pool();
        imdstr.mint(A, AA);
        imdstr.mint(B, BB);
        imdstr.mint(C, CC);
        leaves.push(_leaf(A, AA));
        leaves.push(_leaf(B, BB));
        leaves.push(_leaf(C, CC));
        vm.prank(OWNER);
        L.setClaims(_root(), AA + BB + CC, block.timestamp + 100 days);
        // $IMD and its pool, as on Robinhood, so burnImd has somewhere to buy
        address imd = L.IMD();
        vm.etch(imd, address(new MockImdstr()).code);
        LiquidityAdder adder = new LiquidityAdder(PM);
        vm.deal(address(adder), 100 ether);
        MockImdstr(imd).mint(address(adder), 1e30);
        PM.initialize(L.imdPoolKey(), uint160(_sqrt(261 << 192)));
        adder.add(L.imdPoolKey(), 1e21);
        // the launch, with the excess held here for the timelock (as script/launch.sh launches)
        bytes32 salt = CoinSalt.mine(L);
        address expected = L.tokenAddress(salt);
        uint160 price = uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, 19.18 ether)));
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (coin,) = L.launch{value: BUY}(salt, expected, price, 0, address(L));
        // the perps, from the audited code, with some insurance
        vm.deal(address(this), 1 ether);
        (address e, address v) = pool.createPerps{value: 0.05 ether}(
            vm.getCode("PerpEngine.sol:PerpEngine"), vm.getCode("PerpVault.sol:PerpVault")
        );
        (engine, vault) = (PerpEngine(payable(e)), PerpVault(payable(v)));
        refuser = new Refuser();

        bytes32[][3] memory proofs = [_proof(0), _proof(1), _proof(2)];
        handler = new LaunchHandler(
            PM, L, engine, vault, imdstr, OWNER, TL, [A, B, C], [AA, BB, CC], proofs, address(refuser), PAYEE
        );
        targetContract(address(handler));
    }

    /*                              INVARIANTS                              */

    /// The locked position is all of the pool's liquidity, and it is never taken out
    function invariant_TheLockedPositionIsAllOfThePool() public view {
        PoolId id = pool.poolId();
        uint128 liq = pool.liquidity();
        assertGt(liq, 0, "the position is gone");
        assertEq(PM.getLiquidity(id), liq, "someone else's liquidity, or some of it taken out");
        (uint160 sq,,,) = PM.getSlot0(id);
        assertGt(sq, 0, "the pool the locked pool points at is not initialized");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(id), "the hook serves another pool");
    }

    /// The fee only ever goes down, and is the static fee the pool key carries
    function invariant_TheFeeOnlyGoesDown() public view {
        assertLe(pool.fee(), 44_400);
        assertEq(pool.fee(), handler.ghostLastFee(), "the fee changed without lowerFee");
        assertEq(pool.poolKey().fee, pool.fee());
    }

    /// Every coin is somewhere we can name: nothing is minted, nothing vanishes but what is burned
    function invariant_TheCoinIsConserved() public view {
        IERC20View c = IERC20View(coin);
        uint256 supply = c.totalSupply();
        assertLe(supply, SUPPLY, "minted");
        uint256 sum = c.balanceOf(address(PM)) + c.balanceOf(address(L)) + c.balanceOf(address(pool))
            + c.balanceOf(address(engine)) + c.balanceOf(address(vault)) + c.balanceOf(A) + c.balanceOf(B)
            + c.balanceOf(C) + c.balanceOf(PAYEE) + c.balanceOf(TL);
        uint256 n = handler.traderCount();
        for (uint256 i; i < n; ++i) {
            sum += c.balanceOf(address(handler.traders(i)));
        }
        assertEq(sum, supply, "coins at an address nobody sent them to");
    }

    /// The launch holds every coin it owes: the claims' reserve and the timelock's held excess
    function invariant_TheLaunchHoldsWhatItOwes() public view {
        uint256 held = IERC20View(coin).balanceOf(address(L));
        assertGe(held, L.claimReserve() + L.excessHeld(), "the launch owes more coins than it holds");
        assertLe(L.claimedTotal(), L.claimTotal(), "more claimed than the snapshot");
        assertEq(L.claimedTotal(), handler.ghostClaimed(), "claimedTotal drifted from the claims");
        assertEq(imdstr.balanceOf(address(L)), handler.ghostImdstrIn(), "the IMDSTR leaves the launch");
        assertLe(L.claimedBy(A), AA);
        assertLe(L.claimedBy(B), BB);
        assertLe(L.claimedBy(C), CC);
        if (L.unclaimedReleased()) assertEq(L.claimReserve(), 0);
        else assertEq(L.claimReserve(), L.claimTotal() - L.claimedTotal());
    }

    /// The ETH the launch holds covers what it has set aside: the $IMD bucket, what refused payees are owed and the
    /// perps fees their destination refused
    function invariant_TheLaunchHoldsTheEthItBooked() public view {
        assertGe(address(L).balance, L.imdBucket() + L.owedTotal() + L.perpFeesOwed(), "booked more ETH than held");
        assertEq(
            L.owed(address(refuser)) + L.owed(POT) + L.owed(PAYEE) + L.owed(L.imdBurn()),
            L.owedTotal(),
            "owedTotal is not the sum of what is owed"
        );
        // the bucket only ever holds what the split set aside, so a refused perps fee never feeds the $IMD buy
        assertLe(L.imdBucket(), handler.ghostBucketIn() - handler.ghostBucketOut(), "the bucket grew outside split");
    }

    /// The launch's owner and the timelock's roles never move: no renounce, no transfer the handler didn't make
    function invariant_TheRolesStay() public view {
        assertEq(L.owner(), OWNER, "the launch lost or changed its owner");
        assertEq(L.timelock(), TL);
        assertEq(engine.feeSink(), address(L), "the engine's fees go somewhere else than the launch");
    }

    /// The coin's fee never goes to a person: the pool holds nothing between collects but what it will pay out,
    /// and the perps vault holds nothing at all (it is a pass-through to the engine)
    function invariant_NothingPoolsOutsideTheLedgers() public view {
        assertEq(address(vault).balance, 0, "the vault holds ETH");
        assertEq(IERC20View(coin).balanceOf(address(vault)), 0, "the vault holds coins");
        assertEq(address(hook).balance, 0);
    }

    /// The engine holds at least the ETH its ledgers say: the stakers' free ETH, the insurance, the token side's
    /// yield, the fees owed to the launch, payouts owed, and every open short's backing
    function invariant_TheEngineHoldsWhatItsLedgersSay() public view {
        uint256 booked = engine.plv() + engine.insuranceEth() + engine.tokYieldEth() + engine.feesOwed()
            + engine.payoutOwedTotal() + handler.shortBacking();
        assertGe(address(engine).balance, booked, "the engine's ETH is short of its ledgers");
        uint256 tokens = engine.plvToken() + engine.longSizeToken();
        assertGe(IERC20View(coin).balanceOf(address(engine)), tokens, "the engine's coins are short of its ledgers");
        assertEq(engine.openCount(), engine.openIds().length, "openCount and the open set disagree");
        assertLe(engine.openCount(), engine.MAX_OPEN_POSITIONS());
    }

    /// No bad debt: the sweep inside every trade closes what the trade would sink, so no loss ever outruns both
    /// the insurance and the stakers' ETH
    function invariant_NoBadDebt() public view {
        assertEq(engine.unabsorbedEth(), 0, "a loss outran the insurance and the PLV");
    }

    /// The engine stays wired to the hook and refunded (nobody can unwire it with positions open), and the hook
    /// reports it fee-free
    function invariant_TheEngineStaysWired() public view {
        assertEq(hook.perpEngine(), address(engine));
        assertTrue(hook.perpRefunded());
        assertTrue(pool.isRefunded(address(engine)));
        assertTrue(pool.isRefunded(address(L)));
        assertEq(engine.owner(), TL);
        assertEq(hook.owner(), TL);
    }

    /// The vault's ETH shares are backed: what it says backs them is what the engine holds for the stakers
    function invariant_TheVaultIsBacked() public view {
        assertLe(vault.assetsEth(), engine.totalEth());
        assertLe(engine.longOiEth(), engine.totalEth());
        assertLe(engine.shortOiToken(), engine.totalTokenAssets());
    }

    /// The shape of each run, for the log (forge test -vv): what the handler actually drove
    function afterInvariant() public view {
        console2.log(
            "opens / refused / closes", handler.ghostOpens(), handler.ghostOpenRefusals(), handler.ghostCloses()
        );
        console2.log("liquidations", handler.ghostLiquidations());
        console2.log("fee moves / sweep refusals", handler.ghostFeeLowered(), handler.ghostSweepRefusals());
        console2.log(
            "claimed / sold back / recovered", handler.ghostClaimed(), handler.ghostSold(), handler.ghostEthRecovered()
        );
        console2.log(
            "eth to payees / refused / open now",
            handler.ghostEthToPayees(),
            handler.ghostPayeeRefused(),
            engine.openCount()
        );
        console2.log(
            "imd buys / perp fees forwarded / booked",
            handler.ghostImdBuys(),
            handler.ghostPerpFeesForwarded(),
            handler.ghostPerpFeesBooked()
        );
    }

    /*                               HELPERS                                */

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hash(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function _root() internal view returns (bytes32) {
        return _hash(_hash(leaves[0], leaves[1]), leaves[2]);
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        if (i == 2) {
            p = new bytes32[](1);
            p[0] = _hash(leaves[0], leaves[1]);
        } else {
            p = new bytes32[](2);
            p[0] = leaves[i == 0 ? 1 : 0];
            p[1] = leaves[2];
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }
}
