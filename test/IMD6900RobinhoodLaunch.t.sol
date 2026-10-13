// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMD6900} from "../src/IMD6900.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// The old IMDSTR, as far as claims see it (on Robinhood it also only moves to and from distributors)
contract MockImdstr {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// A plain trader: swaps through the PoolManager as any router would
contract Trader {
    IPoolManager immutable pm;
    PoolKey key;
    constructor(IPoolManager pm_) { pm = pm_; }
    function swap(PoolKey calldata k, bool buy, int256 amountSpecified) external payable returns (BalanceDelta d) {
        key = k;
        d = abi.decode(pm.unlock(abi.encode(buy, amountSpecified)), (BalanceDelta));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool buy, int256 amt) = abi.decode(data, (bool, int256));
        BalanceDelta d = pm.swap(key, SwapParams(buy, amt, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }
    function _settle(Currency c, int128 v) internal {
        if (v < 0) {
            if (c.isAddressZero()) pm.settle{value: uint128(-v)}();
            else { pm.sync(c); IERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-v)); pm.settle(); }
        } else if (v > 0) pm.take(c, address(this), uint128(v));
    }
    receive() external payable {}
}

/// A stand-in perps engine: trades like any router, and its sweep finds nothing to liquidate
contract Engine is Trader {
    constructor(IPoolManager pm_) Trader(pm_) {}
    function sweepLiquidations(address, int256, bool, uint160) external pure returns (uint8) { return 0; }
    function openCount() external pure returns (uint256) { return 0; }
}

/// A perps engine that takes its fee back the way PerpSwapLib.swapLeg does: checkpoint, swap, refund, in its unlock
contract RefundingEngine {
    IPoolManager immutable pm;
    IMD6900LockedPool immutable lp;
    PoolKey key;
    constructor(IPoolManager pm_, IMD6900LockedPool lp_) { (pm, lp) = (pm_, lp_); }
    function sweepLiquidations(address, int256, bool, uint160) external pure returns (uint8) { return 0; }
    function openCount() external pure returns (uint256) { return 0; }
    function swap(PoolKey calldata k, bool buy, int256 amt) external returns (uint256 r0, uint256 r1) {
        key = k;
        (r0, r1) = abi.decode(pm.unlock(abi.encode(buy, amt)), (uint256, uint256));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool buy, int256 amt) = abi.decode(data, (bool, int256));
        lp.feeCheckpoint();
        BalanceDelta d = pm.swap(key, SwapParams(buy, amt, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        (uint256 r0, uint256 r1) = lp.feeRefund(address(this));
        if (buy) {
            pm.settle{value: uint128(-d.amount0())}();
            pm.take(key.currency1, address(this), uint128(d.amount1()));
        } else {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
            pm.settle();
            pm.take(key.currency0, address(this), uint128(d.amount0()));
        }
        return abi.encode(r0, r1);
    }
    receive() external payable {}
}

/// A perps engine whose open positions the test sets (and one that can't say)
contract CountingEngine {
    uint256 public openCount;
    bool public broken;
    function set(uint256 n, bool b) external { (openCount, broken) = (n, b); }
    function sweepLiquidations(address, int256, bool, uint160) external pure returns (uint8) { return 0; }
    fallback() external { revert(); }
}

/// Puts full-range liquidity in a plain pool (the stand-in for $IMD's pool on Robinhood)
contract LiquidityAdder {
    IPoolManager immutable pm; PoolKey key; uint256 liq;
    constructor(IPoolManager pm_) { pm = pm_; }
    function add(PoolKey calldata k, uint256 l) external { (key, liq) = (k, l); pm.unlock(""); }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        (BalanceDelta d,) = pm.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), int256(liq), 0), "");
        pm.settle{value: uint128(-d.amount0())}();
        pm.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
        pm.settle();
        return "";
    }
    receive() external payable {}
}

/// Someone who isn't the locked pool, trying to put liquidity next to it, or to change it
contract Squatter {
    IPoolManager immutable pm; PoolKey key; int24 lo; int24 hi; int256 delta;
    constructor(IPoolManager pm_) { pm = pm_; }
    function modify(PoolKey calldata k, int24 lo_, int24 hi_, int256 delta_) external {
        (key, lo, hi, delta) = (k, lo_, hi_, delta_);
        pm.unlock("");
    }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, delta, 0), "");
        return "";
    }
}

contract IMD6900RobinhoodLaunchTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    IPoolManager constant NO_CODE = IPoolManager(address(0x8366a39CC670B4001A1121B8F6A443A643e40951));
    uint256 constant SUPPLY = 1_000_000_000 ether;
    /// Ethereum's IMD6900 at about 25 ETH market cap: open the coin at 19.18 ETH, so the 2.81 ETH buy lands it there
    uint256 constant OPEN_MC = 19.18 ether;
    uint256 constant BUY = 2.81 ether;

    IPoolManager PM;
    IMD6900RobinhoodLaunch L;
    IMD6900Hook hook;
    IMD6900LockedPool pool;
    MockImdstr imdstr;
    Trader trader;

    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);
    address constant R = address(0x2E7);
    uint256 constant AA = 40_000_000 ether;
    uint256 constant BB = 20_000_000 ether;
    uint256 constant CC = 3_935_747 ether;
    bytes32[] leaves;
    bytes32 SALT;

    function setUp() public {
        PM = IPoolManager(vm.deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        imdstr = new MockImdstr();
        L = _newLaunch(OWNER, PM, address(imdstr), TL);
        hook = L.createHook(HookSalt.mine(L));
        pool = L.pool();
        SALT = CoinSalt.mine(L); // the coin's 0x6900 salt, as script/mine.sh finds it
        imdstr.mint(A, AA); imdstr.mint(B, BB); imdstr.mint(C, CC);
        trader = new Trader(PM);
        vm.deal(address(trader), 100 ether);
        leaves.push(_leaf(A, AA)); leaves.push(_leaf(B, BB)); leaves.push(_leaf(C, CC));
    }

    /*                                ADMISSION                              */

    function test_DeploysOnAFreshChain() public {
        IMD6900RobinhoodLaunch l = _newLaunch(OWNER, NO_CODE, address(imdstr), TL);
        l.createHook(HookSalt.mine(l));
        assertEq(l.owner(), OWNER);
        assertEq(l.pool().hook(), address(l.hook()));
        assertEq(l.hook().pool(), address(l.pool()));
        assertEq(l.pool().launcher(), address(l));
        assertEq(l.hook().owner(), TL, "the hook is the timelock's from birth");
        assertEq(address(l.hook().poolManager()), address(NO_CODE));
    }

    function test_FitsOneTransaction() public {
        uint256 g = gasleft();
        IMD6900RobinhoodLaunch l = _newLaunch(OWNER, PM, address(imdstr), TL);
        uint256 used = g - gasleft();
        emit log_named_uint("launch deploy gas (the same for every deployer: no mining)", used);
        assertLt(used, 1 << 23, "half EIP-7825's per-transaction cap");
        bytes32 s = HookSalt.mine(l);
        g = gasleft();
        l.createHook(s);
        used = g - gasleft();
        emit log_named_uint("createHook gas", used);
        assertLt(used, 1 << 22);
    }

    function test_PassesTheAdmissionScan() public view {
        _scan(vm.getCode("IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch"), "launch creation code");
        _scan(address(L).code, "launch");
        _scan(address(hook).code, "hook");
        _scan(address(pool).code, "pool");
        _scan(type(IMD6900).creationCode, "coin creation code");
    }

    function test_TheHooksAddressAndPermissions() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, L.FLAGS(), "carries exactly its flags");
        assertTrue(uint160(address(hook)) >> 152 != 0x91, "not a 0x91 address");
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
    }

    function test_EachDeployerMinesItsOwnHook() public {
        IMD6900RobinhoodLaunch b = _newLaunch(OWNER, PM, address(imdstr), TL);
        bytes32 s = HookSalt.mine(b);
        b.createHook(s);
        assertTrue(address(b.hook()) != address(hook));
        assertEq(uint160(address(b.hook())) & Hooks.ALL_HOOK_MASK, b.FLAGS());
        assertEq(b.hookSalt(), s);
    }

    function test_TheHookIsCreatedOnceAtAFittingSalt() public {
        IMD6900RobinhoodLaunch b = _newLaunch(OWNER, PM, address(imdstr), TL);
        assertEq(address(b.hook()), address(0));
        assertEq(b.pool().hook(), address(0), "the pool can't open before");
        bytes32 s = HookSalt.mine(b);
        bytes32 s2 = HookSalt.mine(b, uint256(s) + 1);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadHook.selector);
        b.createHook(bytes32(uint256(s2) - 1)); // between two fitting salts: doesn't fit
        vm.prank(address(0xBEEF)); // anyone: every salt it accepts makes the same hook
        IMD6900Hook h = b.createHook(s);
        assertEq(b.pool().hook(), address(h));
        assertEq(h.owner(), TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.HookExists.selector);
        b.createHook(s2);
    }

    /*                                THE LAUNCH                             */

    function test_LaunchesAtEthereumsPrice() public {
        (address t, uint256 bought) = _launch();
        assertEq(t, L.tokenAddress(SALT));
        assertEq(L.token(), t);
        emit log_named_decimal_uint("opening buy, coins", bought, 18);
        // constant product from 19.18 ETH: 2.81 ETH less the pool's 4.44% lands ~12.28%
        assertApproxEqRel(bought, 122_810_000 ether, 0.005e18);
        assertEq(IERC20(t).balanceOf(address(L)), AA + BB + CC, "exactly the claims' reserve stays");
        uint256 burned = L.launchExcess();
        assertEq(IERC20(t).totalSupply(), SUPPLY - burned, "the rest is burned");
        assertEq(address(L).balance, 0, "every wei went into the buy");
        assertEq(address(PM).balance, BUY, "the pool holds the ETH the buy paid (its fee included, in the position)");
        // the price it left: ETH per coin, on a billion coins
        (uint160 sq,,) = pool.state();
        uint256 mc = FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sq), 1 << 96, sq); // coins / (coins per ETH)
        emit log_named_decimal_uint("market cap after the buy, ETH on 1B", mc, 18);
        assertApproxEqRel(mc, 24.93 ether, 0.01e18, "Ethereum's price, about");
    }

    function test_TheCoinIsAt0x6900() public {
        (address t,) = _launch();
        assertEq(uint160(t) >> 144, 0x6900, "0x6900...");
        emit log_named_address("the coin", t);
    }

    function test_RefusesAnAddressThatIsnt0x6900() public {
        _claims();
        vm.deal(OWNER, BUY);
        address plain = L.tokenAddress(bytes32(uint256(0xdead)));
        assertTrue(uint160(plain) >> 144 != 0x6900);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMD6900RobinhoodLaunch.NotVanity.selector, plain));
        L.launch{value: BUY}(bytes32(uint256(0xdead)), plain, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    function test_RefusesTheWrongAddress() public {
        _claims();
        vm.deal(OWNER, BUY);
        (address landed, address mined) = (L.tokenAddress(bytes32(uint256(1))), L.tokenAddress(SALT));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMD6900RobinhoodLaunch.NotWhereMined.selector, landed));
        L.launch{value: BUY}(bytes32(uint256(1)), mined, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    function test_OnlyTheOwnerLaunches() public {
        _claims();
        vm.deal(address(this), BUY);
        address expected_ = L.tokenAddress(SALT);
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.launch{value: BUY}(SALT, expected_, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    function test_LaunchesOnce() public {
        _launch();
        vm.deal(OWNER, 1 ether);
        address expected_ = L.tokenAddress(bytes32(uint256(2)));
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyLaunched.selector);
        L.launch{value: 1 ether}(bytes32(uint256(2)), expected_, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    function test_TheBuyMustCoverTheClaims() public {
        vm.prank(OWNER);
        L.setClaims(_root(), 300_000_000 ether, block.timestamp + 100 days);
        vm.deal(OWNER, BUY);
        address expected_ = L.tokenAddress(SALT);
        vm.prank(OWNER);
        vm.expectRevert(); // Short: 2.81 ETH can't land 300M at this price
        L.launch{value: BUY}(SALT, expected_, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    function test_SendsTheExcessWhereTold() public {
        _claims();
        vm.deal(OWNER, BUY);
        address expected_ = L.tokenAddress(SALT);
        vm.prank(OWNER);
        (address t,) = L.launch{value: BUY}(SALT, expected_, _sqrtPrice(OPEN_MC), 0, TL);
        assertEq(IERC20(t).balanceOf(TL), L.launchExcess());
        assertEq(IERC20(t).totalSupply(), SUPPLY);
    }

    function test_KeepsTheExcessForTheTimelock() public {
        _claims();
        vm.deal(OWNER, BUY);
        address expected_ = L.tokenAddress(SALT);
        vm.prank(OWNER);
        (address t,) = L.launch{value: BUY}(SALT, expected_, _sqrtPrice(OPEN_MC), 0, address(L));
        uint256 excess = L.excessHeld();
        assertGt(excess, 0);
        assertEq(IERC20(t).balanceOf(address(L)), AA + BB + CC + excess, "the reserve and the excess, both here");
        assertEq(IERC20(t).totalSupply(), SUPPLY, "nothing burned");
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.releaseExcess(0, OWNER);
        // the timelock can't reach the claims' reserve through it
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseExcess(excess + 1, TL);
        vm.prank(TL);
        L.releaseExcess(0, TL);
        assertEq(IERC20(t).balanceOf(TL), excess);
        assertEq(IERC20(t).balanceOf(address(L)), AA + BB + CC);
        assertEq(L.excessHeld(), 0);
    }

    function test_EthComesBackBeforeTheLaunchOnly() public {
        vm.deal(address(L), 1 ether);
        vm.prank(OWNER);
        L.withdrawEth(OWNER, 0);
        assertEq(OWNER.balance, 1 ether);
        _launch();
        vm.deal(address(L), 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyLaunched.selector);
        L.withdrawEth(OWNER, 0);
    }

    function test_ClaimsCantChangeAfterTheLaunch() public {
        _launch();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyLaunched.selector);
        L.setClaims(bytes32(uint256(1)), 1, block.timestamp + 365 days);
    }

    function test_ClaimsStayOpenNinetyDays() public {
        vm.prank(OWNER);
        L.setClaims(_root(), AA + BB + CC, block.timestamp + 30 days);
        vm.deal(OWNER, BUY);
        address expected_ = L.tokenAddress(SALT);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        L.launch{value: BUY}(SALT, expected_, _sqrtPrice(OPEN_MC), 0, address(0));
    }

    /*                               THE POOL                               */

    function test_TradesBothWays() public {
        (address t,) = _launch();
        PoolKey memory k = pool.poolKey();
        BalanceDelta d = trader.swap(k, true, -1 ether);
        assertGt(d.amount1(), 0, "bought");
        uint256 coins = IERC20(t).balanceOf(address(trader));
        uint256 eth0 = address(trader).balance;
        trader.swap(k, false, -int256(coins));
        assertGt(address(trader).balance, eth0, "sold back");
        assertEq(IERC20(t).balanceOf(address(trader)), 0);
    }

    function test_TheLiquidityIsLocked() public {
        _launch();
        PoolKey memory k = pool.poolKey();
        uint128 liq = pool.liquidity();
        Squatter s = new Squatter(PM);
        int24 upper = pool.upperTick();
        // nobody else can add, in the pool's range or any other
        vm.expectRevert();
        s.modify(k, TickMath.minUsableTick(60), upper, 1e18);
        vm.expectRevert();
        s.modify(k, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e18);
        // the pool itself has no way out: collecting leaves the position as it was
        trader.swap(k, true, -1 ether);
        pool.collect();
        (,, uint128 inPool) = pool.state();
        assertEq(pool.liquidity(), liq);
        assertEq(inPool, liq, "all of the pool's liquidity is the locked position");
    }

    function test_HarvestSplitsTheEthAndBurnsTheCoin() public {
        (address t,) = _launch();
        PoolKey memory k = pool.poolKey();
        trader.swap(k, true, -10 ether); // 0.1 ETH of fees
        uint256 coins = IERC20(t).balanceOf(address(trader));
        trader.swap(k, false, -int256(coins / 2)); // fees in the coin
        uint256 supply = IERC20(t).totalSupply();
        uint256 potBefore = POT.balance;
        uint256 ownerBefore = OWNER.balance;
        L.harvest();
        uint256 toPot = POT.balance - potBefore;
        emit log_named_decimal_uint("pot bridge", toPot, 18);
        uint256 fees = toPot + L.imdBucket();
        assertApproxEqRel(fees, (10 ether + BUY) * 444 / 10_000, 0.001e18, "4.44% of the buys, the opening buy's included");
        assertApproxEqRel(toPot, fees * 9 / 10, 1e14, "90% the NFT floor pot");
        assertApproxEqRel(L.imdBucket(), fees / 10, 1e14, "10% set aside for $IMD's canonical burn");
        assertEq(OWNER.balance, ownerBefore, "nothing to the team");
        assertLt(IERC20(t).totalSupply(), supply, "the coin's fees are burned");
        assertEq(address(L).balance, L.imdBucket(), "only the $IMD share stays");
    }

    function test_BurnsImdThroughItsExecutor() public {
        // $IMD and its pool, as on Robinhood: ETH / $IMD, 1%, tick spacing 100, no hooks
        address imd = L.IMD();
        vm.etch(imd, address(new MockImdstr()).code);
        LiquidityAdder adder = new LiquidityAdder(PM);
        vm.deal(address(adder), 100 ether);
        MockImdstr(imd).mint(address(adder), 1e30);
        PoolKey memory ik = L.imdPoolKey();
        PM.initialize(ik, uint160(_sqrt(261 << 192))); // ~261 $IMD per ETH
        adder.add(ik, 1e21);

        (address t,) = _launch();
        vm.deal(address(trader), 200 ether);
        trader.swap(pool.poolKey(), true, -150 ether); // 1.5 ETH of fees: 0.15 set aside for $IMD
        L.harvest();
        uint256 bucket = L.imdBucket();
        assertGt(bucket, 0.1 ether, "more than one call's worth");
        uint256 got = L.burnImd(0);
        assertEq(MockImdstr(imd).balanceOf(L.IMD_BURN()), got, "the $IMD is at the burn executor");
        assertApproxEqRel(got, 0.099 ether * 261, 0.02e18, "0.1 ETH of $IMD, less the pool's fee");
        assertEq(L.imdBucket(), bucket - 0.1 ether, "at most 0.1 ETH a call");
        assertEq(L.imdBurned(), got);
        t;
    }

    function test_OnlyTheTimelockSetsTheSplit() public {
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0], to[1], bps[1]) = (POT, 8_000, L.IMD_BURN(), 2_000);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setPayees(to, bps);
        vm.prank(TL);
        L.setPayees(to, bps);
        (address[] memory got, uint16[] memory gotBps) = L.payees();
        assertEq(got.length, 2);
        assertEq(gotBps[0], 8_000);
        // and the new split is what the fees follow
        (address t,) = _launch();
        trader.swap(pool.poolKey(), true, -10 ether);
        uint256 potBefore = POT.balance;
        L.harvest();
        assertApproxEqRel(POT.balance - potBefore, (POT.balance - potBefore + L.imdBucket()) * 8 / 10, 1e14, "80 / 20");
        t;
    }

    /*                                THE FEE                                */

    function test_TheFeeIsStatic() public {
        _launch();
        PoolKey memory k = pool.poolKey();
        assertEq(k.fee, 44_400, "4.44%, a plain static fee: Uniswap routes it on its own");
        assertEq(hook.perpFeeBps(), 444, "what the perps engine prices its own swaps at");
        (address[] memory to, uint16[] memory bps) = L.payees();
        assertEq(to.length, 2);
        assertEq(to[0], L.POT_BRIDGE());
        assertEq(bps[0], 9_000, "90% the NFT floor pot");
        assertEq(to[1], L.IMD_BURN());
        assertEq(bps[1], 1_000, "10% $IMD's canonical burn");
        trader.swap(k, true, -1 ether);
        (uint256 eth,) = pool.collect();
        assertApproxEqRel(eth, (1 ether + BUY) * 444 / 10_000, 0.001e18, "4.44% of the buys, the opening buy's included");
    }

    function test_LowerFeeMovesTheLiquidity() public {
        (address t,) = _launch();
        PoolKey memory old = pool.poolKey();
        trader.swap(old, true, -5 ether); // fees earned in the old pool
        (uint160 p0,,) = pool.state();
        uint128 l0 = pool.liquidity();
        uint256 supply = IERC20(t).totalSupply();
        uint256 lBefore = address(L).balance;
        vm.prank(TL);
        uint128 l1 = pool.lowerFee(33_300);
        PoolKey memory neu = pool.poolKey();
        assertEq(neu.fee, 33_300);
        assertEq(hook.perpFeeBps(), 333, "the engine sees the lower fee");
        (uint160 p1,, uint128 inPool) = pool.state();
        assertEq(p1, p0, "same price");
        assertApproxEqRel(l1, l0, 1e9, "all of the liquidity moved (to the wei of rounding)");
        assertEq(inPool, l1, "and it is all the new pool has");
        assertEq(PM.getLiquidity(old.toId()), 0, "the old pool is empty");
        assertApproxEqRel(address(L).balance - lBefore, (5 ether + BUY) * 444 / 10_000, 0.001e18, "only the old pool's earned fees came out");
        assertLe(IERC20(t).totalSupply(), supply, "its IMD6900 fees burned");
        // trading goes on in the new pool, at the new fee; the old one is closed
        trader.swap(neu, true, -1 ether);
        (uint256 eth,) = pool.collect();
        assertApproxEqRel(eth, 0.0333 ether, 0.001e18);
        vm.expectRevert();
        trader.swap(old, true, -1 ether);
    }

    function test_OnlyTheTimelockLowersTheFeeAndOnlyDown() public {
        _launch();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900LockedPool.OnlyTimelock.selector);
        pool.lowerFee(33_300);
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        pool.lowerFee(44_400);
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        pool.lowerFee(100_000);
        vm.prank(TL);
        pool.lowerFee(0); // no fee at all, if the timelock ever wants it
        assertEq(pool.fee(), 0);
        trader.swap(pool.poolKey(), true, -1 ether);
        (uint256 eth,) = pool.collect();
        assertEq(eth, 0);
    }

    function test_TheEngineTradesFeeFree() public {
        (address t,) = _launch();
        RefundingEngine engine = new RefundingEngine(PM, pool);
        vm.deal(address(engine), 10 ether);
        vm.prank(TL);
        hook.setPerpEngine(address(engine));
        PoolKey memory k = pool.poolKey();
        (uint256 r0,) = engine.swap(k, true, -1 ether);
        assertApproxEqAbs(r0, 0.0444 ether, 1e10, "the buy's 4.44% back, in ETH");
        assertApproxEqAbs(address(engine).balance, 9 ether + r0, 0, "it paid 1 ETH and got the fee straight back");
        uint256 coins = IERC20(t).balanceOf(address(engine));
        (, uint256 r1) = engine.swap(k, false, -int256(coins));
        assertApproxEqRel(r1, coins * 444 / 10_000, 1e12, "the sell's 4.44% back, in the coin");
        // a trader in between pays as usual, and only its fee (and the opening buy's) reaches the split
        trader.swap(k, true, -1 ether);
        (uint256 eth,) = pool.collect();
        assertApproxEqRel(eth, (1 ether + BUY) * 444 / 10_000, 0.001e18, "the engine's fees never reach the split");
    }

    function test_OnlyTheEngineAndTheLaunchAreRefunded() public {
        _launch();
        assertTrue(pool.isRefunded(address(L)), "the launch's sale");
        assertFalse(pool.isRefunded(address(trader)));
        assertFalse(pool.isRefunded(address(0)), "no engine wired: nobody else");
        vm.prank(address(trader));
        vm.expectRevert(IMD6900LockedPool.NotRefunded.selector);
        pool.feeCheckpoint();
        RefundingEngine engine = new RefundingEngine(PM, pool);
        vm.prank(TL);
        hook.setPerpEngine(address(engine));
        assertTrue(pool.isRefunded(address(engine)));
        vm.prank(address(engine)); // a refund needs the same caller's checkpoint, in the same transaction
        vm.expectRevert(IMD6900LockedPool.NoCheckpoint.selector);
        pool.feeRefund(address(engine));
    }

    function test_TheHookReportsTheEnginesFee() public {
        _launch();
        assertEq(hook.perpFeeBps(), 444, "until the timelock says the engine takes it back");
        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setPerpRefunded(true);
        vm.prank(TL);
        hook.setPerpRefunded(true);
        assertEq(hook.perpFeeBps(), 0, "then only Uniswap's protocol fee, none today");
        assertEq(hook.launcher(), address(pool), "where the engine finds its refunds");
    }

    function test_TheCoinFeeGoesWhereTheTimelockSays() public {
        (address t,) = _launch();
        PoolKey memory k = pool.poolKey();
        trader.swap(k, true, -1 ether);
        trader.swap(k, false, -int256(IERC20(t).balanceOf(address(trader))));
        vm.prank(OWNER);
        vm.expectRevert(IMD6900LockedPool.OnlyTimelock.selector);
        pool.setCoinFeeTo(R);
        vm.prank(TL);
        pool.setCoinFeeTo(R);
        (, uint256 coinsFee) = pool.collect();
        assertGt(coinsFee, 0);
        assertEq(IERC20(t).balanceOf(R), coinsFee, "not burned: sent where it was pointed");
    }

    function test_NoFeeMoveWhilePerpsAreOpen() public {
        _launch();
        CountingEngine engine = new CountingEngine();
        vm.prank(TL);
        hook.setPerpEngine(address(engine));
        engine.set(3, false); // positions open: the engine's pool is fixed for good, a move would strand them
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.PerpsOpen.selector);
        pool.lowerFee(33_300);
        vm.etch(address(engine), hex"fe"); // an engine that can't even say counts as holding positions
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.PerpsOpen.selector);
        pool.lowerFee(33_300);
        vm.etch(address(engine), type(CountingEngine).runtimeCode);
        engine.set(0, false); // every position closed
        vm.prank(TL);
        pool.lowerFee(33_300);
        assertEq(pool.fee(), 33_300, "with nothing open the move goes through");
    }

    function test_ThePerpsEngineTradesThroughTheHook() public {
        _launch();
        Engine engine = new Engine(PM);
        vm.deal(address(engine), 10 ether);
        vm.prank(TL);
        hook.setPerpEngine(address(engine));
        engine.swap(pool.poolKey(), true, -1 ether); // its own trade: no sweep
        trader.swap(pool.poolKey(), true, -1 ether); // a trader's: the engine's (empty) sweep runs first
        (uint256 eth,) = pool.collect();
        assertApproxEqRel(eth, (2 ether + BUY) * 444 / 10_000, 0.001e18, "both pay the pool's fee, into the protocol's own position");
    }

    function test_OnlyTheTimelockRepointsImdsPool() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setImdPool(3000, 60, address(0));
        vm.prank(TL);
        L.setImdPool(3000, 60, address(0));
        assertEq(L.imdPoolFee(), 3000);
    }

    /*                               CLAIMS                                 */

    function test_ClaimsOneForOne() public {
        (address t,) = _launch();
        bytes32[] memory pa = _proof(0);
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        L.claim(AA / 2, AA, pa);
        L.claim(AA / 2, AA, pa);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(1, AA, pa);
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(A), AA);
        assertEq(imdstr.balanceOf(address(L)), AA, "the IMDSTR stays here");
        assertEq(L.claimReserve(), BB + CC);
    }

    function test_ClaimsNeedTheSnapshot() public {
        _launch();
        bytes32[] memory pb = _proof(1);
        vm.startPrank(B);
        imdstr.approve(address(L), type(uint256).max);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(BB, BB * 2, pb); // a bigger allowance than the snapshot's
        vm.stopPrank();
        imdstr.mint(address(0xBAD), 1e24);
        vm.startPrank(address(0xBAD));
        imdstr.approve(address(L), type(uint256).max);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1e24, 1e24, pb); // not on the list
        vm.stopPrank();
    }

    function test_TheUnclaimedRestAfterTheDeadline() public {
        (address t,) = _launch();
        vm.startPrank(C);
        imdstr.approve(address(L), CC);
        L.claim(CC, CC, _proof(2));
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ClaimsOpen.selector);
        L.releaseUnclaimed(address(0));
        vm.warp(block.timestamp + 101 days);
        uint256 supply = IERC20(t).totalSupply();
        vm.prank(OWNER);
        L.releaseUnclaimed(address(0));
        assertEq(IERC20(t).totalSupply(), supply - AA - BB, "burned");
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        bytes32[] memory pa = _proof(0);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.claim(AA, AA, pa);
        vm.stopPrank();
    }

    /*                        THE OPENING BUY'S ETH, BACK                     */

    function test_TheTimelockSellsTheExcessBack() public {
        (address t,) = _launchHeld();
        uint256 held = L.excessHeld();
        assertGt(held, 0);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.sellHeld(0, 0, OWNER);
        vm.prank(TL);
        vm.expectPartialRevert(IMD6900RobinhoodLaunch.Short.selector);
        L.sellHeld(0, BUY, R); // the floor holds
        vm.prank(TL);
        uint256 eth = L.sellHeld(0, 0, R);
        emit log_named_decimal_uint("the excess alone, sold back: ETH", eth, 18);
        assertEq(R.balance, eth);
        assertLt(L.excessHeld(), held / 10_000, "fee-free: only 4.44% cubed of it came back unsold");
        assertEq(IERC20(t).balanceOf(address(L)), AA + BB + CC + L.excessHeld(), "the claims' reserve untouched");
    }

    function test_EndingTheClaimsBringsMostOfTheBuyBack() public {
        (address t,) = _launchHeld();
        vm.startPrank(C); // a holder who claimed keeps it
        imdstr.approve(address(L), CC);
        L.claim(CC, CC, _proof(2));
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.endClaims();
        vm.prank(TL);
        L.endClaims();
        assertEq(L.claimReserve(), 0);
        assertEq(L.excessHeld(), IERC20(t).balanceOf(address(L)), "everything held is the timelock's to sell");
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        bytes32[] memory pa = _proof(0);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.claim(AA, AA, pa);
        vm.stopPrank();
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.endClaims();
        // the split's ETH to the team too, then everything held sold back
        address[] memory to = new address[](1);
        uint16[] memory bps = new uint16[](1);
        (to[0], bps[0]) = (R, 10_000);
        vm.prank(TL);
        L.setPayees(to, bps);
        vm.prank(TL);
        L.sellHeld(0, 0, R);
        L.harvest();
        emit log_named_decimal_uint("back of the 2.81 ETH buy (C's claim kept by C)", R.balance, 18);
        assertGe(R.balance, BUY * 90 / 100, "most of it");
        assertLt(IERC20(t).balanceOf(address(L)), 20_000 ether, "dust of the last round's refund");
    }

    function test_NoClaimsAllOfItBack() public {
        (address t,) = _launchHeld();
        vm.prank(TL);
        L.endClaims();
        address[] memory to = new address[](1);
        uint16[] memory bps = new uint16[](1);
        (to[0], bps[0]) = (R, 10_000);
        vm.prank(TL);
        L.setPayees(to, bps);
        vm.prank(TL);
        L.sellHeld(0, 0, R);
        L.harvest();
        emit log_named_decimal_uint("back of the 2.81 ETH buy, nobody claimed", R.balance, 18);
        assertGe(R.balance, BUY * 99 / 100, "all of it: the sale is fee-free, the buy's fee comes back through the split");
        assertLt(IERC20(t).balanceOf(address(L)), 20_000 ether, "dust of the last round's refund");
    }

    function test_PerpFeesGoAllToThePot() public {
        _launch();
        uint256 potBefore = POT.balance;
        vm.deal(address(0xE9), 1 ether);
        vm.prank(address(0xE9)); // the perps engine's flushFees
        L.addPerpFees{value: 1 ether}();
        assertEq(POT.balance - potBefore, 1 ether, "all of it, as ETH, to the pot bridge");
        assertEq(address(L).balance, 0, "none split or kept");
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setPerpFeeTo(OWNER);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPerpFeeTo(address(0));
        vm.prank(TL);
        L.setPerpFeeTo(R);
        vm.deal(address(0xE9), 1 ether);
        vm.prank(address(0xE9));
        L.addPerpFees{value: 1 ether}();
        assertEq(R.balance, 1 ether, "where the timelock points it");
    }

    function test_OnlyTheTimelockRepointsTheBurnExecutor() public {
        assertEq(L.imdBurn(), 0x4D6537ec564aFf82eABb1Ce5f355E817cBEA1e07, "IMD's canonical Robinhood burn executor");
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.setImdBurn(R);
        vm.prank(TL);
        L.setImdBurn(R);
        assertEq(L.imdBurn(), R);
        (address[] memory to,) = L.payees();
        assertEq(to[1], R, "the default split follows it");
    }

    /*                         OWNER AND TIMELOCK                           */

    function test_OnlyTheTimelockRecoversEth() public {
        _launch();
        vm.deal(address(L), 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.recoverEth(OWNER, 0);
        vm.prank(TL);
        L.recoverEth(TL, 0);
        assertEq(TL.balance, 1 ether);
    }

    function test_OnlyTheTimelockRunsTheHook() public {
        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setPerpEngine(address(1));
        vm.prank(TL);
        hook.setPerpEngine(address(1));
        assertEq(hook.perpEngine(), address(1));
        vm.prank(TL);
        vm.expectRevert(IMD6900Hook.NoRenounce.selector);
        hook.renounceOwnership();
    }

    function test_TheCoinIsPlain() public {
        (address t,) = _launch();
        IMD6900 c = IMD6900(t);
        assertEq(c.name(), "Identity.MD 6900");
        assertEq(c.symbol(), "IMD6900");
        assertEq(c.decimals(), 18);
        // no owner, no mint: the only way supply changes is a holder burning its own
        (bool ok,) = t.call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = t.call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
    }

    /*                               HELPERS                                */

    function _launch() internal returns (address t, uint256 bought) {
        return _launch(address(0));
    }

    /// @dev As script/launch.sh launches (both ways): the excess kept here for the timelock
    function _launchHeld() internal returns (address t, uint256 bought) {
        return _launch(address(L));
    }

    function _launch(address excessTo) internal returns (address t, uint256 bought) {
        _claims();
        vm.deal(OWNER, BUY);
        address expected_ = L.tokenAddress(SALT);
        vm.prank(OWNER);
        (t, bought) = L.launch{value: BUY}(SALT, expected_, _sqrtPrice(OPEN_MC), 0, excessTo);
    }

    function _claims() internal {
        vm.prank(OWNER);
        L.setClaims(_root(), AA + BB + CC, block.timestamp + 100 days);
    }

    /// @dev The opening price for a market cap of `mc` ETH on a billion coins: coins per ETH, as a v4 sqrt price
    function _sqrtPrice(uint256 mc) internal pure returns (uint160) {
        return uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, mc))); // coins per ETH (both 18 decimals), times 2^192
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }

    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hash(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    /// three leaves: ((0, 1), 2)
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

    /// @dev The launch from its build artifact (as deployed), rather than `new`: a test contract that embeds the
    ///      launch's creation code (and the PoolManager's, and the perps') costs the swarm's build machine too much
    function _newLaunch(address owner_, IPoolManager pm, address imdstr_, address tl) internal returns (IMD6900RobinhoodLaunch) {
        return IMD6900RobinhoodLaunch(payable(vm.deployCode("IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch", abi.encode(owner_, pm, imdstr_, tl))));
    }
}
