# Adaptation notes: IMD6900RobinhoodLaunch on Robinhood Chain (evm_contracts launch)

The project arrived launchable as it is: one contract, `IMD6900RobinhoodLaunch`, four constructor arguments
(owner, PoolManager, IMDSTR, timelock), a nonpayable constructor that creates `IMD6900LockedPool` and calls nothing
that existed before it, no DELEGATECALL / CALLCODE / SELFDESTRUCT anywhere (creation code included), the hook created
later by `createHook(salt)` from a salt mined off-chain, the perps created later by `createPerps` from code checked by
hash. None of the launch rules required a change: the owner is a constructor argument (never `msg.sender`), nothing is
upgradeable, nothing mints, pauses, freezes or seizes, the coin is a plain ERC-20 refused unless at `0x6900…`.

Build and compiler settings are untouched (solc 0.8.26, via-IR, 200 runs, cancun, `bytecode_hash = "none"`), as are
the constructor, the hook's permission flags, the 4.44% static fee, `lowerFee`'s lower-only move and its refusal while
the perps engine has positions open, the fee refund pair, the fee split's defaults and the timelock's setters, and
`src/perps/*` (so `ENGINE_CODE_HASH` and `VAULT_CODE_HASH` are unchanged and `test_ThePerpsCodeIsTheAuditedCode`
holds).

What changed is what the imported audit found. Each finding was reproduced by reading the exact code path, and
each fix carries a test. Rehearsed locally: `forge build`, `forge test` (62 tests, all passing, with the verifier's
fuzz seed), and the protected admission test (`Contracts.protected.t.sol`) against the launch's creation code with
the four real constructor arguments: constructor runs on an empty chain, runtime 23,849 bytes (under EIP-170's
24,576), no forbidden opcodes.

Deploy gas, measured on a local anvil node with the real arguments (the in-test figure from `vm.deployCode` is not
a measurement): 8,019,186 gas, against 7,788,069 for the unmodified commit (runtime 22,779 bytes). The brief's
"about 6.9M" predates the perps additions already in the commit as it arrived; the fixes here add about 3%. It fits
one transaction (under half of EIP-7825's cap, as `test_FitsOneTransaction` requires) and is the same from any
deployer.

## 1. `split()` re-split a refused payee's share (audit: medium) — fixed

**Reproduced.** `split()` paid each payee `balance - imdBucket` pro rata and, on a failed call, only emitted
`PayFailed`: the refused ETH stayed in the contract's balance and the next permissionless `split()` divided it again
among all payees. With the default payees (pot bridge 90%, $IMD burn 10%) and a reverting bridge, every call moved
10% of what remained into `imdBucket`: after n calls `1 - 0.9^n` of the pot's ETH had become $IMD buys. The NatSpec
("leaves it here for the next split") described per-payee bookkeeping the code did not have.

**Change** (`src/IMD6900RobinhoodLaunch.sol`):

- `owed(address)` and `owedTotal`: what a payee refused is booked to it. `split()` divides only
  `balance - imdBucket - owedTotal` and offers each payee its share plus what it is owed; a successful payment clears
  the booking, a failed one grows it. `PayFailed` now reports the whole amount offered.
- `setPayees` (timelock) cancels the booking of any payee the new list drops (`OwedCancelled`), so the next split
  divides it among the payees of the day: dropping a payee is the timelock's way to stop paying it. Payees kept in
  the list, in any order, keep what they are owed.
- `setImdBurn` cancels a booking for the new executor (its share is set aside for `burnImd` from then on, not sent).
- `recoverEth` (timelock) drops the bookings when the ETH behind them leaves, the same way it already clamped
  `imdBucket`.

**Tests** (`test/IMD6900RobinhoodLaunch.t.sol`): `test_ARefusedShareIsOwedNotReSplit` (the audit's reproduction: the
pot bridge refusing, 50 splits, the bucket stays at 0.1 ETH and 0.9 ETH stays booked to the bridge),
`test_AnOwedShareIsPaidOnceThePayeeAccepts`, `test_DroppingAPayeeCancelsWhatItWasOwed`,
`test_RecoverEthDropsTheBookings`.

Not changed, noted: a payee that burns all forwarded gas (an `INVALID` opcode, not a plain revert) can still make
`split()` run out of gas; payees are the timelock's to set and to drop, and `recoverEth` remains the escape hatch.

## 2. Unwiring or replacing the perps engine stranded its open positions (audit: medium) — fixed

**Reproduced.** `IMD6900LockedPool.isRefunded` accepts the launch and the engine currently wired in the hook.
`PerpSwapLib.swapLeg` calls `feeCheckpoint()` before every engine swap whenever the hook exposes `launcher()`. After
`IMD6900Hook.setPerpEngine(other)` (or zero), the old engine's `close()`, `liquidate()` and every settlement revert
`NotRefunded`: traders cannot exit and their collateral stays locked. `lowerFee` then succeeds (the hook has no engine
or the new one has no positions) and binds the old engine to an empty pool for good.

**Change** (`src/IMD6900Hook.sol`): `setPerpEngine` refuses (`PerpsOpen`) while the wired engine reports
`openCount() != 0` and the call would point elsewhere. An engine that cannot answer `openCount()` (reverts or returns
nothing) stays replaceable: that broken wiring is what the escape hatch is for, and `lowerFee` already treats such an
engine as holding positions. Setting the same engine again is allowed. The `openCount` probe is shared with the
existing low-gas path of `_sweep` (`_openPositions`, bounded to 100k gas like `lowerFee`'s).

The audit's alternatives (letting `swapLeg` skip the refund when not refunded, or `isRefunded` accepting
`LockedPool.perpsEngine`) would have changed `src/perps` and the audited code hashes, or widened who trades fee-free;
the hook-side guard is the smaller change and keeps `lowerFee`'s check sufficient (an engine with positions open is
always the wired one). Consequence, by design and as the brief states: the fee cannot be lowered while any perps
position is open.

**Tests**: `test/Perps.t.sol: test_TheEngineCantBeUnwiredWithPositionsOpen` (the real engine: a long open, unwiring
and replacing revert, the long closes, then unwiring succeeds) and
`test/IMD6900RobinhoodLaunch.t.sol: test_TheEngineCantBeUnwiredWithPositionsOpen` (the same engine re-set, the broken
engine replaceable).

## 3. `sellHeld`'s fee refund lost when the post-trade sweep liquidated (audit: low) — fixed

**Reproduced.** In the launch's unlock, round i: `pool.feeCheckpoint()` (the launch's), the swap, `pool.feeRefund`.
The hook's `_afterSwap` runs inside that window and sweeps; a liquidation there runs `PerpSwapLib.swapLeg`, whose own
`feeCheckpoint()` pokes every fee accrued so far, the sale's 4.44% included, into the locked pool. The launch's
`feeRefund` then finds nothing: `back = 0`, `sold = paid`, and the sale pays the full fee despite the exemption. The
pre-trade sweep (`_beforeSwap`) is harmless: it runs before the sale's fee accrues, and its liquidation's own
checkpoint/refund pair takes only that liquidation's fee.

**Change** (`src/IMD6900Hook.sol`): `_afterSwap` skips the best-effort post-trade sweep when the swap's sender is the
locked pool's launcher (the launch contract, read through `ILockedPoolView.launcher()`). The pre-trade sweep still
runs for the sale, so what the sale would sink is still liquidated before it at the price before it moves (the
no-bad-debt guarantee is unchanged); what the sale's final price leaves under water is closed by the next trade's
sweep or a permissionless `liquidate()`, as for any trade's post-sweep that runs out of gas. Narrower than the audit's
"skip the hook's sweeps" (both), and no change to `src/perps`.

**Tests**: `test/IMD6900RobinhoodLaunch.t.sol: test_TheSalesRefundSurvivesALiquidationInTheSweep` (a stand-in
engine whose sweeps liquidate with the real engine's checkpoint/swap/refund sequence: the pre-trade sweep runs and
sells, no post-trade sweep runs inside the sale, the sale's fee comes back; a trader's swap still gets both sweeps)
and `test/Perps.t.sol: test_TheTimelocksSaleSweepsFirstAndKeepsItsRefund` (the real engine: a 5x long the sale
sinks is liquidated in the pre-trade sweep with no bad debt, and the sale stays fee-free).

## 4. Review scope (audit: info) — nothing to fix

A coverage statement, not a defect. Noted that the audit was traced by reading, not run.

## Test infrastructure (not a contract change)

`test/HookSalt.sol`: the salt miners (`HookSalt`, `CoinSalt`) hashed `abi.encodePacked(...)` once per try, growing
memory by 85 bytes a try; the quadratic memory cost made a long search (the coin's 16-bit vanity, up to tens of
thousands of tries for an unlucky deployer address) run out of gas. `test_ThePerpsCodeIsTheAuditedCode` failed this
way on the unmodified commit (`MemoryOOG`). The address is now hashed in fixed scratch memory (`Create2Address.at`),
so a search costs no memory however long it runs. The salts found are the same.

`README.md`: two sentences updated for the hook's new behaviour (the post-trade sweep and `setPerpEngine`).

## Launch facts for the manifest step (not written here)

Kind `evm_contracts`, one contract `IMD6900RobinhoodLaunch`, constructor arguments in order:
`0x35da9c0303507ddf708e87f2568eddf12c47a059` (owner, the team wallet), `0x8366a39CC670B4001A1121B8F6A443A643e40951`
(Uniswap v4 PoolManager on Robinhood Chain), `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F` (IMDSTR),
`0x16D3f65B708883DF042d98E1C7a49B32A33E2A14` (the Robinhood timelock). The constructor creates `IMD6900LockedPool`
and nothing else; the hook (`createHook`, salt mined off-chain by `script/launch.sh hook` against the launch's
address and `hookInitCodeHash()`) and the perps (`createPerps`) come after, from the team.
