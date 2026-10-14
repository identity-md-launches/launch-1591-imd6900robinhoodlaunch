// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {PerpEngine} from "../src/perps/PerpEngine.sol";
import {PerpVault} from "../src/perps/PerpVault.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {MockImdstr, Trader} from "./IMD6900RobinhoodLaunch.t.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// The perps, as the launch ships them: created by the locked pool right after the launch from exactly the audited
/// code, owned by the timelock, wired into the hook at once, and trading fee-free by refund in the locked pool.
contract PerpsTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    address constant STAKER = address(0x57A4E);
    address constant ALICE = address(0xA1);
    uint256 constant BUY = 2.81 ether;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    IPoolManager PM;
    IMD6900RobinhoodLaunch L;
    IMD6900Hook hook;
    IMD6900LockedPool pool;
    PerpEngine engine;
    PerpVault vault;
    address t;
    PoolKey k;

    function setUp() public {
        PM = IPoolManager(vm.deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        (L, hook, pool) = _deploy();
        t = _launch(L);
        vm.deal(address(this), 1 ether);
        (address e, address v) =
            pool.createPerps{value: 0.05 ether}(_engineCode(), _vaultCode());
        (engine, vault) = (PerpEngine(payable(e)), PerpVault(payable(v)));
        k = pool.poolKey();
        vm.deal(STAKER, 20 ether);
        vm.prank(STAKER);
        vault.depositEth{value: 10 ether}(); // the community's ETH side: what longs borrow
        vm.deal(ALICE, 5 ether);
        pool.collect(); // the opening buy's fees out of the way
    }

    function test_ThePerpsAreCreatedAndWired() public view {
        assertEq(pool.perpsEngine(), address(engine));
        assertEq(pool.perpsVault(), address(vault));
        assertEq(engine.owner(), TL, "the timelock owns every risk lever from the start");
        assertEq(engine.vault(), address(vault));
        assertEq(engine.feeSink(), address(L), "its fees: the launch, on to the NFT pot");
        assertEq(engine.token(), t);
        assertEq(PoolId.unwrap(engine.poolId()), PoolId.unwrap(pool.poolId()), "this pool");
        assertEq(engine.insuranceEth(), 0.05 ether, "the ETH sent along");
        assertEq(hook.perpEngine(), address(engine), "live at once: no timelock wait after the launch");
        assertTrue(hook.perpRefunded());
        assertEq(hook.perpFeeBps(), 0, "fee-free by refund: only Uniswap's protocol fee would be left");
        assertEq(engine.vaultYieldBps(), 2_000, "20% to the stakers");
        assertEq(engine.insuranceBps(), 1_000, "10% insurance, the rest to the pot");
    }

    function test_ThePerpsCodeIsTheAuditedCode() public {
        assertEq(keccak256(_engineCode()), pool.ENGINE_CODE_HASH(), "the engine this commit builds");
        assertEq(keccak256(_vaultCode()), pool.VAULT_CODE_HASH(), "the vault this commit builds");
        vm.expectRevert(IMD6900LockedPool.PerpsExist.selector);
        pool.createPerps(_engineCode(), _vaultCode());
        // a fresh launch: not before the pool opens, and not any other code
        (IMD6900RobinhoodLaunch l2,, IMD6900LockedPool p2) = _deploy();
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        p2.createPerps(_engineCode(), _vaultCode());
        _launch(l2);
        bytes memory other = abi.encodePacked(_engineCode(), hex"00");
        vm.expectRevert(IMD6900LockedPool.NotThePerpsCode.selector);
        p2.createPerps(other, _vaultCode());
        vm.expectRevert(IMD6900Hook.OnlyPool.selector);
        hook.initPerpEngine(address(1));
    }

    function test_ThePerpsPassTheAdmissionScan() public view {
        _scan(_engineCode(), "engine creation code");
        _scan(_vaultCode(), "vault creation code");
        _scan(address(engine).code, "engine");
        _scan(address(vault).code, "vault");
        assertLe(address(engine).code.length, 24_576, "under the code size limit");
    }

    function test_ALongRoundTripPaysNoPoolFee() public {
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        uint256 id = engine.openLong{value: 0.1 ether}(5, 0);
        (uint256 eth,) = pool.collect();
        assertLe(eth, 1e9, "the engine's buy paid the pool nothing (dust of rounding)");
        vm.prank(ALICE);
        engine.close(id, 0);
        (, uint256 coins) = pool.collect();
        assertLe(coins, 1e15, "nor its sell");
        uint256 back = ALICE.balance - (before - 0.1 ether);
        emit log_named_decimal_uint("a 0.1 ETH 5x long, opened and closed: back", back, 18);
        assertGe(back, 0.0925 ether, "the collateral less the 6.9% open fee, nothing for the pool");
        assertEq(engine.unabsorbedEth(), 0);
    }

    function test_AShortRoundTrip() public {
        // a staker brings the token side: what shorts borrow
        Trader buyer = new Trader(PM);
        vm.deal(address(buyer), 3 ether);
        buyer.swap(k, true, -2 ether);
        uint256 coins = IERC20Min(t).balanceOf(address(buyer));
        vm.prank(address(buyer));
        IERC20Min(t).approve(address(vault), coins);
        vm.prank(address(buyer));
        vault.depositToken(coins);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        uint256 id = engine.openShort{value: 0.1 ether}(3, 0);
        vm.prank(ALICE);
        engine.close(id, 0);
        uint256 back = ALICE.balance - (before - 0.1 ether);
        emit log_named_decimal_uint("a 0.1 ETH 3x short, opened and closed: back", back, 18);
        assertGe(back, 0.0925 ether);
        assertEq(engine.unabsorbedEth(), 0);
    }

    function test_AWhaleDumpLiquidatesInTheHooksSweepFirst() public {
        Trader whale = new Trader(PM);
        vm.deal(address(whale), 10 ether);
        whale.swap(k, true, -3 ether);
        vm.prank(ALICE);
        uint256 id = engine.openLong{value: 0.1 ether}(5, 0);
        assertFalse(engine.isLiquidatable(id));
        uint256 stakers = engine.totalEth();
        uint256 keeper = tx.origin.balance;
        // the dump would sink the long: the hook's pre-trade sweep closes it at the price before the dump moves it
        whale.swap(k, false, -int256(IERC20Min(t).balanceOf(address(whale))));
        assertEq(engine.openCount(), 0, "liquidated inside the whale's swap");
        assertEq(engine.unabsorbedEth(), 0, "no bad debt");
        assertGe(engine.totalEth(), stakers, "the stakers' ETH whole");
        assertGt(tx.origin.balance, keeper, "the keeper's cut to whoever sent the swap");
    }

    function test_PerpFeesReachThePot() public {
        vm.prank(ALICE);
        engine.openLong{value: 0.3 ether}(2, 0); // a position is capped at 3.5% of the pool's depth
        uint256 owed = engine.feesOwed();
        assertApproxEqRel(owed, 0.3 ether * 690 / 10_000 * 7 / 10, 1e12, "70% of the 6.9% open fee");
        uint256 potBefore = POT.balance;
        engine.flushFees();
        assertEq(POT.balance - potBefore, owed, "all of it, as ETH, to the pot bridge");
    }

    /// The audit's second finding: unwiring the engine stranded every open position (their closes revert NotRefunded)
    function test_TheEngineCantBeUnwiredWithPositionsOpen() public {
        vm.prank(ALICE);
        uint256 id = engine.openLong{value: 0.1 ether}(5, 0);
        vm.prank(TL);
        vm.expectRevert(IMD6900Hook.PerpsOpen.selector);
        hook.setPerpEngine(address(0));
        vm.prank(TL);
        vm.expectRevert(IMD6900Hook.PerpsOpen.selector);
        hook.setPerpEngine(address(0xBEEF));
        assertEq(hook.perpEngine(), address(engine));
        vm.prank(ALICE);
        engine.close(id, 0); // still wired, so it closes
        assertEq(engine.openCount(), 0);
        vm.prank(TL);
        hook.setPerpEngine(address(0)); // nothing open: the way out stays
        assertEq(hook.perpEngine(), address(0));
    }

    /// The audit's third finding, with the real engine: the timelock's sale with a long the sale sinks. The pre-trade
    /// sweep liquidates it (no bad debt), and the sale keeps its fee refund all the same
    function test_TheTimelocksSaleSweepsFirstAndKeepsItsRefund() public {
        vm.prank(ALICE);
        uint256 id = engine.openLong{value: 0.1 ether}(5, 0);
        assertFalse(engine.isLiquidatable(id));
        pool.collect();
        uint256 held = L.excessHeld();
        uint256 stakers = engine.totalEth();
        vm.prank(TL);
        uint256 eth = L.sellHeld(0, 0, TL); // everything the opening buy landed, back into the pool
        assertGt(eth, 0);
        assertEq(engine.openCount(), 0, "liquidated in the sale's pre-trade sweep");
        assertEq(engine.unabsorbedEth(), 0, "no bad debt");
        assertGe(engine.totalEth(), stakers, "the stakers' ETH whole");
        assertLt(L.excessHeld(), held / 10_000, "fee-free: only 4.44% cubed of it came back unsold");
        (, uint256 coins) = pool.collect();
        assertLt(coins, held / 100_000, "the sale's fee came back to the launch, not into the pool");
    }

    function test_NoFeeMoveWithAPositionOpen() public {
        vm.prank(ALICE);
        engine.openLong{value: 0.1 ether}(5, 0);
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.PerpsOpen.selector);
        pool.lowerFee(33_300);
    }

    function test_OnlyTheTimelockTunesThePerps() public {
        vm.expectRevert();
        engine.setFees(500, 690, 145);
        vm.prank(TL);
        engine.setFees(500, 690, 145); // the perps' usage fee, adjustable
        assertEq(engine.openFeeBps(), 500);
        vm.prank(TL);
        engine.setVaultSplit(3_000, 1_000); // the stakers' share, adjustable
        assertEq(engine.vaultYieldBps(), 3_000);
    }

    /*                               HELPERS                                */

    function _deploy() internal returns (IMD6900RobinhoodLaunch l, IMD6900Hook h, IMD6900LockedPool p) {
        l = _newLaunch(OWNER, PM, address(new MockImdstr()), TL);
        h = l.createHook(HookSalt.mine(l));
        p = l.pool();
    }

    function _launch(IMD6900RobinhoodLaunch l) internal returns (address coin) {
        bytes32 salt = CoinSalt.mine(l);
        address expected = l.tokenAddress(salt);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (coin,) = l.launch{value: BUY}(salt, expected, uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, 19.18 ether))), 0, address(l));
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

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }

    /// @dev The launch from its build artifact (as deployed), rather than `new`: a test contract that embeds the
    ///      launch's creation code (and the PoolManager's, and the perps') costs the swarm's build machine too much
    function _newLaunch(address owner_, IPoolManager pm, address imdstr_, address tl) internal returns (IMD6900RobinhoodLaunch) {
        return IMD6900RobinhoodLaunch(payable(vm.deployCode("IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch", abi.encode(owner_, pm, imdstr_, tl))));
    }

    function _engineCode() internal view returns (bytes memory) {
        return vm.getCode("PerpEngine.sol:PerpEngine");
    }

    function _vaultCode() internal view returns (bytes memory) {
        return vm.getCode("PerpVault.sol:PerpVault");
    }
}
