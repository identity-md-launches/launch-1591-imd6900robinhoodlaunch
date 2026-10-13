// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {PerpEngine} from "../src/perps/PerpEngine.sol";
import {PerpVault} from "../src/perps/PerpVault.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IImdstr is IERC20 {
    function setDistributor(address, bool) external;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// v4-periphery's IV4Router.ExactInputSingleParams
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

contract ForkTrader {
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

/// The launch on live Robinhood Chain state (ROBINHOOD_RPC_URL; skips without it): the real v4 PoolManager, the real
/// IMDSTR (it moves only to and from distributors, so the timelock's op is played first), the real pot bridge, real
/// snapshot holders claiming, and a buy through Uniswap's own Universal Router: the pool is routable as deployed.
contract RobinhoodForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IImdstr constant IMDSTR = IImdstr(0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F);
    address constant TL = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14;
    address constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    IUniversalRouter constant UR = IUniversalRouter(0x204FAca1764B154221e35c0d20aBb3c525710498);
    /// two snapshot holders (snapshots/rh-community-2026-10-09.json)
    address constant H1 = 0x431a27e55bB3a949C9E377860193cBb488efC71e;
    address constant H2 = 0x5B5f858689D57aEC42B674234d6cdD4bEc86f983;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    IMD6900RobinhoodLaunch L;
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
        L = new IMD6900RobinhoodLaunch(TEAM, PM, address(IMDSTR), TL);
        L.createHook(HookSalt.mine(L));
    }

    function test_TheWholeLaunchOnRobinhood() public {
        if (!live) return;
        uint256 b1 = IMDSTR.balanceOf(H1);
        uint256 b2 = IMDSTR.balanceOf(H2);
        bytes32 l1 = keccak256(bytes.concat(keccak256(abi.encode(H1, b1))));
        bytes32 l2 = keccak256(bytes.concat(keccak256(abi.encode(H2, b2))));
        bytes32 root = l1 < l2 ? keccak256(abi.encodePacked(l1, l2)) : keccak256(abi.encodePacked(l2, l1));
        vm.prank(TEAM);
        L.setClaims(root, b1 + b2, block.timestamp + 91 days);

        // the launch: Ethereum's ~25 ETH market cap after a 2.81 ETH buy (4.44% of it the pool's fee)
        vm.deal(TEAM, 2.81 ether);
        bytes32 salt = CoinSalt.mine(L); // 0x6900, as script/mine.sh finds it
        address expected = L.tokenAddress(salt);
        uint160 sp = uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, 19.40 ether)));
        vm.prank(TEAM);
        (address t, uint256 bought) = L.launch{value: 2.81 ether}(salt, expected, sp, 0, address(L)); // as launch.sh: the excess kept
        emit log_named_decimal_uint("opening buy, coins", bought, 18);
        IMD6900LockedPool pool = L.pool();
        uint128 locked = pool.liquidity();
        (uint160 sq,,) = pool.state();
        emit log_named_decimal_uint("market cap after it, ETH on 1B", FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sq), 1 << 96, sq), 18);
        assertEq(IERC20(t).balanceOf(address(L)), b1 + b2 + L.excessHeld(), "the claims' reserve and the excess, both here");

        // claims open with the timelock's op, as on the day
        vm.prank(TL);
        IMDSTR.setDistributor(address(L), true);
        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = l2;
        vm.startPrank(H1);
        IMDSTR.approve(address(L), b1);
        L.claim(b1, b1, p1);
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(H1), b1, "1:1");
        assertEq(IMDSTR.balanceOf(address(L)), b1);

        // anyone trades on the live PoolManager, both ways
        ForkTrader tr = new ForkTrader(PM);
        vm.deal(address(tr), 5 ether);
        PoolKey memory k = pool.poolKey();
        tr.swap(k, true, -1 ether);
        uint256 coins = IERC20(t).balanceOf(address(tr));
        assertGt(coins, 0);
        tr.swap(k, false, -int256(coins));
        assertEq(IERC20(t).balanceOf(address(tr)), 0);

        // and through Uniswap's Universal Router
        address buyer = address(0xB0B);
        vm.deal(buyer, 1 ether);
        _routerBuy(buyer, k, 0.5 ether);
        emit log_named_decimal_uint("bought through the Universal Router", IERC20(t).balanceOf(buyer), 18);
        assertGt(IERC20(t).balanceOf(buyer), 0, "Uniswap's router trades the pool");

        // the fees: ETH 90% to the pot bridge (the NFT floor pot), 10% to $IMD's canonical burn; the coin's burned
        uint256 potBefore = POT.balance;
        uint256 supply = IERC20(t).totalSupply();
        L.harvest();
        emit log_named_decimal_uint("to the pot bridge", POT.balance - potBefore, 18);
        assertGt(POT.balance, potBefore);
        assertLt(IERC20(t).totalSupply(), supply);
        // the $IMD share: bought on $IMD's Robinhood pool, sent to its official burn executor
        address exec = L.IMD_BURN();
        uint256 execBefore = IERC20(L.IMD()).balanceOf(exec);
        uint256 got = L.burnImd(0);
        emit log_named_decimal_uint("$IMD bought for the burn executor", got, 18);
        assertEq(IERC20(L.IMD()).balanceOf(exec) - execBefore, got);
        (uint160 sq1,, uint128 inPool) = pool.state();
        assertEq(pool.liquidity(), locked, "the position never moved");
        assertEq(inPool, locked, "and it is all the pool has");

        // the perps, created right after the launch from the audited code (by hash), live at once, fee-free by refund
        vm.deal(address(this), 1 ether);
        (address e, address v) = pool.createPerps{value: 0.05 ether}(type(PerpEngine).creationCode, type(PerpVault).creationCode);
        PerpEngine engine = PerpEngine(payable(e));
        assertEq(engine.owner(), TL);
        vm.deal(address(0x57A4E), 5 ether);
        vm.prank(address(0x57A4E));
        PerpVault(payable(v)).depositEth{value: 3 ether}();
        address alice = address(0xA11CE5);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 id = engine.openLong{value: 0.05 ether}(5, 0);
        vm.prank(alice);
        engine.close(id, 0);
        emit log_named_decimal_uint("a 0.05 ETH 5x long, opened and closed on live state: back", alice.balance - 0.95 ether, 18);
        assertGe(alice.balance - 0.95 ether, 0.046 ether, "the collateral less the 6.9% open fee: no pool fee");
        assertEq(engine.openCount(), 0);
        uint256 potPerps = POT.balance;
        engine.flushFees();
        assertGt(POT.balance, potPerps, "the perps' fees to the pot bridge");

        // the timelock lowers the fee: the position moves to a 3.33% pool at the same price, in one transaction
        uint256 potBefore2 = POT.balance;
        (sq1,,) = pool.state(); // the price the perps round trip left
        vm.prank(TL);
        uint128 moved = pool.lowerFee(33_300);
        PoolKey memory k2 = pool.poolKey();
        assertEq(k2.fee, 33_300);
        (uint160 sq2,, uint128 inPool2) = pool.state();
        assertEq(sq2, sq1, "same price");
        assertEq(inPool2, moved);
        assertApproxEqRel(moved, locked, 1e9, "all of it, to the wei of rounding");
        assertEq(PM.getLiquidity(k.toId()), 0, "the 4.44% pool is empty");
        uint256 before2 = IERC20(t).balanceOf(buyer);
        _routerBuy(buyer, k2, 0.5 ether);
        emit log_named_decimal_uint("bought through the Universal Router at 3.33%", IERC20(t).balanceOf(buyer) - before2, 18);
        assertGt(IERC20(t).balanceOf(buyer), before2, "Uniswap's router trades the new pool");
        vm.expectRevert();
        tr.swap(k, true, -0.1 ether);
        L.harvest();
        assertGt(POT.balance, potBefore2, "the new pool's fees reach the pot");

        // and the opening buy's ETH back, if the team wants it: the timelock ends the claims (H2 never claimed) and
        // sells everything the launch holds back into the pool (after the trades above moved the price)
        uint256 teamBefore2 = TEAM.balance;
        vm.prank(TL);
        L.endClaims();
        vm.prank(TL);
        uint256 back = L.sellHeld(0, 0, TEAM);
        emit log_named_decimal_uint("sold back to the team, ETH", back, 18);
        assertEq(TEAM.balance - teamBefore2, back);
        assertGt(back, 2 ether, "most of the 2.81");
        assertLt(L.excessHeld(), 20_000 ether, "fee-free rounds: dust left");
    }

    /// @dev V4_SWAP (SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), ETH in
    function _routerBuy(address buyer, PoolKey memory k, uint256 amount) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(k, true, uint128(amount), 0, ""));
        params[1] = abi.encode(k.currency0, amount);
        params[2] = abi.encode(k.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        vm.prank(buyer);
        UR.execute{value: amount}(hex"10", inputs, block.timestamp + 60);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }
}
