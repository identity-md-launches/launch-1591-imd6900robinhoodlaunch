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

What changed is what the imported audit found (sections 1–4) and what the independent review of the accepted work
found (section 5). Each finding was reproduced by reading the exact code path or by running the reviewer's proof, and
each fix carries a test. Rehearsed locally: `forge build`, `forge test` (67 tests, all passing, with the verifier's
fuzz seed and an empty environment), and the protected admission test (`Contracts.protected.t.sol`) against the
launch's creation code with the four real constructor arguments: constructor runs on an empty chain, runtime 24,022
bytes (under EIP-170's 24,576), no forbidden opcodes.

Deploy gas, measured on a local anvil node with the real arguments (the in-test figure from `vm.deployCode` is not
a measurement): 8,056,611 gas, against 7,788,069 for the unmodified commit (runtime 22,779 bytes). The brief's
"about 6.9M" predates the perps additions already in the commit as it arrived; the fixes here add about 3.5%. It fits
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

## 5. The independent review of the accepted work (this revision)

The verifier's Slither runs crashed in Slither's own code (see the next section), so the work above was first
resubmitted unchanged; the review that then read it reported the findings below. Each was reproduced before anything
changed. `src/perps/*` is still untouched (the audited code hashes hold).

### 5a. `burnImd`'s cap bounded one call, not one transaction (review: medium, with a proof) — fixed

**Reproduced** with the reviewer's proof: `burnImd` is permissionless and `nonReentrant` only blocks nesting, so one
transaction looping it spent the whole 0.678 ETH bucket at whatever price the same transaction had pushed the $IMD pool
to; `IMD_BUY_MAX` (0.1 ETH, "under what sandwiching it would be worth") bounded nothing.

**Change** (`src/IMD6900RobinhoodLaunch.sol`): `burnImd` records `lastImdBuy = block.timestamp` and reverts
`BoughtThisBlock` when called again at the same timestamp. One transaction, and one block, can spend at most
`IMD_BUY_MAX`; the next timestamp buys again. A timestamp rather than `block.number`: on an Arbitrum-based chain such as
Robinhood's, `block.number` is the L1's, and a timestamp bounds a transaction on any chain. The constant's NatSpec now
states the guarantee it gives. **Test**: `test_OneImdBuyATimestamp` (a loop of eleven calls spends 0.1 ETH, the repeat
reverts, the next second buys again), and the reviewer's proof (`Proof_644c65575bf3.t.sol`) passes.

The proof had failed on the verifier with `vm.deployCode: no matching artifact found`: its build compiles `src/`, the
non-test helpers in `test/` and the proof, without the project's `*.t.sol` files, which were the only importers of
v4-core's `PoolManager`. `test/PoolManagerArtifact.sol` (compile-only, one import, also imported by `test/HookSalt.sol`)
keeps the artifact in such a build. Rehearsed on a copy of the tree with every `*.t.sol` removed and the proof under
`test/imd-proof-4ad035ff/`: it passes there. Not a contract change; `PoolManager` is still used by the tests only.

### 5b. The bucket debited by the offer, not by what the $IMD pool took (review: low) — fixed

**Reproduced**: with the stand-in pool's liquidity in one band, the pool took 0.0075 ETH of the 0.1 ETH offered, the
bucket fell by 0.1 ETH, and the next `split()` would have sent 90% of the difference to the pot bridge.
**Change**: `unlockCallback` returns `(out, ethIn)` for both buys; `burnImd` debits `imdBucket` by `ethIn` after the
unlock (and emits it); `launch()` decodes the pair (its own buy cannot underfill with 1B coins of liquidity).
**Test**: `test_TheBucketIsDebitedByWhatThePoolTook` (nothing beyond the split's rounding wei is left unbooked).

### 5c. `claim()` never bounded `claimedTotal` by `claimTotal` (review: low) — fixed

**Reproduced**: a one-leaf root (40M) set with `claimTotal` 20M paid 40M, 20M of it from the timelock's held coins,
and `claimReserve()`, `releaseUnclaimed()` and `endClaims()` then underflowed. **Change**: `claim()` reverts
`OverClaim` when `claimedTotal + amount > claimTotal`. **Test**: `test_ClaimsNeverPassTheReserve`.

### 5d. `renounceOwnership` unguarded on the launch (review: low) — fixed

**Reproduced**: solady's `Ownable.renounceOwnership` succeeded and left `owner() == 0`, which before the launch kills
`launch()` itself. **Change**: overridden to revert `NoRenounce`, as the hook and the engine already do.
**Test**: `test_TheLaunchCantBeRenounced`.

### 5e. `addPerpFees` reverted on a refusing destination (review: low) — fixed

**Reproduced** by tracing `PerpEngine.flushFees` → `addPerpFees` → `SafeTransferLib.safeTransferETH`: a paused pot
bridge made every flush revert and the engine's `feesOwed` grow until the timelock repointed it. **Change**: a
tolerant call; what the destination refuses is booked as `perpFeesOwed`, excluded from `split()`'s base, offered again
with the next forwarding (to wherever `perpFeeTo` points then) and dropped by `recoverEth` together with the other
bookings. Never split: the perps' 70% stays the perps fee destination's. **Test**:
`test_RefusedPerpFeesWaitForTheNextForwarding`; `test_PerpFeesReachThePot` (the real engine's flush) unchanged.

### 5f. Not changed, recorded

- **PerpVault's virtual shares and ETH in the PLV before the first deposit** (review: low). The arithmetic is as
  reported: what `fundPlv` / `fundPlvToken` (the timelock, the engine's owner) or the engine's 20% fee share puts in the
  PLV before anyone holds shares is priced into the 1e6 virtual shares, and so is their pro-rata part of all later
  yield. It costs the funder only, never a depositor, and the fee share cannot precede a deposit in practice (an open
  needs shares to lend against). `src/perps` is pinned by `ENGINE_CODE_HASH` / `VAULT_CODE_HASH` as the audited code,
  so this is an operating rule for the timelock: fund the PLV only after the first community deposit.
- **After `lowerFee` the hash-checked perps cannot be recreated** (review: info): `createPerps` is one-shot, the engine
  binds its pool at creation, so a fee move leaves the engine failing closed (as documented) until the timelock wires a
  hand-deployed one through `IMD6900Hook.setPerpEngine`, which checks no code hash. Trust assumption, unchanged.
- **The engine's caps are sized against the virtual full-range depth** (review: info): about 8x the real in-range ETH
  at the opening state (2.69 ETH real against 21.9 ETH virtual), so `maxNotionalBps` 3.5% is ~29% of the real ETH.
  No bad debt follows (the price cannot leave the position's range while any coin is outside the pool); the caps are
  the timelock's to tune on the live engine. Unchanged.
- **The timelock's powers are undelayed in these contracts** (review: info): the delay is the external timelock's, as
  the brief and README say. One addition from this revision: `perpFeesOwed` follows `setPerpFeeTo` at the next
  forwarding and is dropped by `recoverEth`, like `owed` and `imdBucket`.

## Static analysis: Slither's crash, Aderyn in its place (no contract change)

The verifier's Slither runs crashed in Slither's own code, so the work above was first resubmitted unchanged for the
analyzers to be re-run; this section records what they say.

Slither 0.11.6 crashes on this repository with `AssertionError` in `slithir/convert.py: convert_constant_types`
(`assert len(types) == len(ir.arguments)`). Traced with a probe around that function: the node is
`PerpEngine._book`, the expression `_addOpen(id, Position(trader, isLong, uint128(collateral), size, principal,
uint64(block.timestamp), leverage, fundingIndex))`, a struct literal built inline as a call argument. Slither's IR
cannot type that argument list; solc compiles it, and the tests exercise it on every open. It is left as it is:
rewriting the perps engine to suit an analyzer's bug would change `src/perps` and so `ENGINE_CODE_HASH`, which the
brief pins to the audited code, for no behavioural reason. The verifier now accepts Aderyn where Slither crashes.

Aderyn 0.6.8 (88 detectors, `aderyn .` on this tree) reports 6 "high" and 17 "low" classes. Each "high" was checked
against the code and none reproduces as a defect:

- `abi.encodePacked` hash collision: the five sites concatenate `creationCode` with an `abi.encode(...)` of the
  constructor arguments to form CREATE2 init code (the hook, the coin, the perps). That is the init code itself, not a
  hash of two dynamic values; there is nothing to collide.
- Contract locks Ether: `IMD6900LockedPool.receive()` takes the pool manager's ETH fees and `_payOutHeld` forwards the
  whole balance to the launch's `addFees` on every collect and move; `PerpVault` has `withdrawEth`; `IMD6900Hook` has
  no `receive` and takes ETH only through Solady `Ownable`'s payable `transferOwnership` / `renounceOwnership`, which
  the timelock would have to send on purpose.
- ETH transferred without address checks: `PerpEngine.claimPayout` pays `msg.sender` its own booked payout.
- Reentrancy, state change after external call: every site is a `nonReentrant` function (or the launch's and the
  pool's unlock callbacks, which only the pool manager may enter) writing results the external call returned; the
  imported audit read the same paths and reported none.
- Storage array edited with memory: `_liqTest(positions[id])` is a `view` test over a copy and writes nothing.
- Unsafe casting: `uint128(collateral)` is an ETH amount net of the open fee; `uint128` holds 3.4e20 ETH.

The "low" classes are style (literals, uninitialized loop counters, modifier order, the `^0.8.26` pragma every source
file carries while foundry.toml pins solc 0.8.26), the documented centralization in the timelock's setters, or the raw
ERC-20 calls in `PerpSwapLib.tryTransfer` / `tryTransferFrom`, which decode the returned data themselves and exist so
a refusing token cannot grief a payout. None was changed.

Re-run for this revision, on this machine: `forge build` (solc 0.8.26, via-IR), `forge test` with the verifier's
fuzz seed and an empty environment (67 passed, 0 failed, plus the reviewer's proof), and `Contracts.protected.t.sol`
against the launch's creation code with the four real constructor arguments on chain id 4663 (passes: constructor on
an empty chain, runtime 24,022 bytes within EIP-170, no CALLCODE / DELEGATECALL / SELFDESTRUCT).

## Launch facts for the manifest step (not written here)

Kind `evm_contracts`, one contract `IMD6900RobinhoodLaunch`, constructor arguments in order:
`0x35da9c0303507ddf708e87f2568eddf12c47a059` (owner, the team wallet), `0x8366a39CC670B4001A1121B8F6A443A643e40951`
(Uniswap v4 PoolManager on Robinhood Chain), `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F` (IMDSTR),
`0x16D3f65B708883DF042d98E1C7a49B32A33E2A14` (the Robinhood timelock). The constructor creates `IMD6900LockedPool`
and nothing else; the hook (`createHook`, salt mined off-chain by `script/launch.sh hook` against the launch's
address and `hookInitCodeHash()`) and the perps (`createPerps`) come after, from the team.
