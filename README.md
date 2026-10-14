# IMD6900 on Robinhood Chain: the coin, a locked Uniswap v4 pool, the perps hook

Identity.MD 6900 (IMD6900) relaunched on Robinhood Chain as a plain coin with its whole supply in a locked Uniswap v4
pool, deployed by the IMD swarm (`evm_contracts`) and launched through Programmable (custom launch, open provenance) at a
0x6900… address. It replaces the old IMDSTR market (pulled to the Pons launcher, 2.83 ETH): that ETH is the opening buy,
and the old IMDSTR claims the new coin 1:1, up to each holder's snapshot balance.

## The contracts

| | |
|---|---|
| `src/IMD6900RobinhoodLaunch.sol` | What the swarm deploys. Its constructor creates the locked pool and calls nothing that existed before it (~6.9M gas, the same from any deployer). `createHook(salt)` (anyone, once) then creates the hook at a salt mined off-chain for its address. Then the launch, the claims, the fee split. |
| `src/IMD6900.sol` | The coin: 1B minted once to the launch. No owner, no mint, no tax, no pause, no blacklist, no limits, no proxy. Holders can burn their own. |
| `src/IMD6900LockedPool.sol` | Owns the pool's one position. No owner, no way to take liquidity out. `collect()` (anyone): ETH fees to the split, IMD6900 fees burned (or to `setCoinFeeTo`'s address). `lowerFee(fee)` (the timelock only, lower only, never with perps open): moves the position, in one transaction, into a new pool at the lower fee and the same price. `feeCheckpoint()` / `feeRefund(to)`: the perps engine and the launch's sale trade fee-free (below). |
| `src/IMD6900Hook.sol` | ETH / IMD6900 only, at the locked pool's static fee, initialized by the locked pool only (at the launch, and at each lower fee it moves to), liquidity from it only. Charges nothing itself: no dynamic fee, no return deltas. In-pool perps: before every swap that isn't the engine's own, the engine (once the timelock wires one) liquidates every position the swap would sink, at the price before it moves; a best-effort second sweep after (not after the launch's own sale of held coins, which would lose the sale its fee refund). The engine can't be unwired or replaced while it reports positions open. Reports the pool's fee to the engine (`perpFeeBps`). Not upgradeable. Owned by the Robinhood timelock. |

## The launch, one transaction

`launch(salt, expectedToken, sqrtPriceX96, minBought, excessTo)`, from the team wallet, with the ETH:

1. creates IMD6900 with CREATE2 from the launch (reverts unless it lands at `expectedToken`, and unless that address starts
   with 0x6900: `script/mine.sh` mines the salt for the deployed launch);
2. opens the pool at `sqrtPriceX96` with all 1B as IMD6900-only liquidity from that price down: no ETH needed, locked;
3. buys first with every wei the launch holds (nobody can trade before: the coin didn't exist a moment earlier);
4. keeps the claims' reserve, and keeps the rest of what it bought in the launch: only the timelock moves it (`sellHeld`, `releaseExcess`, the timelock's public delay (24h)), so no wallet ever holds it.

The opening price and the buy come from `script/params.py`, so that after the buy the coin trades at exactly IMD6900's
Ethereum price: the pool opens on a tick (0.6% apart), so it rounds the opening onto one and sizes the buy to land on
the price from there (today: open at ~19.5 ETH market cap, buy ~2.77 of the 2.81 ETH, 4.44% fee included, land at
~25.15 = Ethereum's, ~119.5M bought). The pool's fee (4.44% on every trade, the opening buy's too) is all the protocol's
(the locked position is the pool's only liquidity). Its ETH splits 90% to the pot bridge (it feeds IMD6900's NFT floor
pot on Ethereum) and 10% to $IMD's canonical burn (bought on $IMD's Robinhood pool, sent to IMD's official burn
executor `0x4D6537ec564aFf82eABb1Ce5f355E817cBEA1e07`, fixed in the code, which bridges it to Base); nothing to the
team. The fee paid in IMD6900 (on sells) is burned: the pot bridge carries ETH only. The perps engine's fees (its open fee
and liquidation penalties, after its stakers' 20% and insurance's 10%, both editable in the engine) come in through
`addPerpFees()` and go on, all of it, as ETH to the pot bridge (what it refuses waits here, `perpFeesOwed`, for the next
forwarding, so a paused bridge never blocks the engine's flush). Every landing address is the timelock's to change: the
split's payees and shares (`setPayees`), the perps fees' (`setPerpFeeTo`), the IMD6900 fees' (`setCoinFeeTo`, burned by
default), IMD's burn executor (`setImdBurn`, the canonical one by default), $IMD's pool (`setImdPool`). The plan: most
of it to the NFT floor pot for now, later (one timelock batch, no redeploy) to a contract rewarding the frens who link
their fren NFT as their identity.md avatar.

The road to the pot, end to end (each step anyone's to call; `script/launch.sh pot` does them all): `harvest()` here,
`burnImd(min)` for the $IMD share (0.1 ETH at most per block timestamp, so no single transaction can buy more at a price
it pushed), the pot bridge's `bridge()` (Robinhood → Across → Ethereum, from 0.05 ETH), then on
Ethereum the pot hook's `depositBridgedFees()` (`0xA160…6444`), which adds it to the NFT pot: the strategy buys
identity.md NFTs at the floor with it, and what it resells them for buys IMD6900 on Ethereum. Rehearsed on forks of
both chains: 0.1 ETH bridged over Across, then 0.0995 into the pot. The split is the Robinhood timelock's to change (`setPayees`, the timelock's public delay (24h)).

## The fee, and routing

Two callers trade fee-free, by refund: the hook's perps engine and the launch (the timelock's sale of held coins).
Inside its own swap such a caller calls the locked pool's `feeCheckpoint()` just before and `feeRefund(to)` just after;
the locked pool owns all of the liquidity, so what it earned between the two is that swap's fee, to the wei, and it
goes straight back. Everyone else pays the pool's 4.44%; nothing about the pool or the hook changes for Uniswap's
router. The hook reports the engine's cost (`perpFeeBps`): the pool's fee until the timelock sets `perpRefunded` along
with a refund-aware engine (PerpSwapLib.swapLeg), then only Uniswap's protocol fee (none today).

4.44%, a plain static fee: Uniswap's router quotes the pool on its own (no dynamic fee, no return deltas, not a 0x91
hook; Programmable's plan opts in to the hook list and Uniswap's API too). A v4 pool's fee can't change, so lowering it
means a new pool: `lowerFee(newFee)` (the timelock, behind its 24h delay; only ever lower, 0 allowed) initializes the
ETH / IMD6900 pool at `newFee` at the current price, and moves the whole position there in one unlock. Nothing leaves
but the old pool's earned fees (to the split, like any `collect`); the old pool is left empty and its swaps revert; the
new one is routable the same way (the fork test buys through the Universal Router before and after a move to 3.33%).

## The opening buy's ETH, back if wanted

Before the launch the ETH never leaves the team wallet (`withdrawEth` returns anything sent early). After it, the ETH
sits in the pool against the coins the buy landed, and the launch holds those coins. The timelock (the timelock's public delay (24h))
can sell them back into the pool, ETH to any address (`sellHeld(amount, minEth, to)`), and can end the claims early
(`endClaims()`: the unclaimed reserve joins what it can sell; holders see it 24h ahead and can claim first; what they
claimed is theirs). The sale is fee-free (the refund above, three rounds in one transaction), so selling everything
right after the launch returns what the buy put into the curve; the buy's own 4.44% went to the split (all of it back
too if the timelock points the split at the team for that harvest). In tests: 2.8098 of 2.81 ETH with nobody's claim
kept; on a Robinhood fork after other trades and a fee move, 2.75; the excess alone, claims kept, ~1.37. Later, it
depends on the price the market left. `script/launch.sh recover` (`END_CLAIMS=1` for the reserve too) queues it, `recover-exec` runs it.

## Perps, live from the launch

`src/perps/`: PerpEngine and PerpVault (ported from MiFrens Cauldron's audited engine, the IMD6900 rules: 6.9% open fee
on collateral, 2-5x, no bad debt by construction), with PerpSwapLib inlined (no DELEGATECALL anywhere). The engine's
constructor binds to the live pool, so it can't exist before the coin: `IMD6900LockedPool.createPerps(engineCode,
vaultCode)` creates it right after `launch()` (anyone, once; `script/launch.sh perps`), only from exactly this source
(`ENGINE_CODE_HASH`, `VAULT_CODE_HASH`; test_ThePerpsCodeIsTheAuditedCode), with the ETH sent as insurance; the
Robinhood timelock owns the engine from that same transaction and the hook serves it at once (`initPerpEngine`), so
perps trade from the first block after the launch. Every later change is the timelock's (24h).

- Fees: open fee and liquidation penalty split 20% stakers (the vault), 10% insurance, 70% to the launch, which sends
  it all as ETH to the NFT floor pot (`setFees`, `setVaultSplit`: the timelock's to change). The engine's pool fee comes
  straight back (refund), so traders pay only the open fee: a 5x long opened and closed returns its collateral less
  6.9%, on live Robinhood state too.
- Liquidations: before every swap that isn't the engine's own, the hook has the engine close every position the swap
  would sink, at the price before it moves (a whale's dump liquidates the long first: no bad debt, stakers whole, the
  sender of the swap takes the keeper's cut). A sweep that can't run reverts the swap; the timelock (24h) can set
  `sweepFailOpen` or unwire the engine (never while it reports positions open: only the wired engine trades fee-free,
  so an unwired one's closes would revert and strand them; one that can't say is replaceable).
- The engine is bound to its pool for good, so `lowerFee` refuses while it has positions open (or can't say); after a
  move it fails closed until the timelock wires a new one.
- Liquidity for perps is the community's: ETH stakers (longs borrow it), token stakers (shorts borrow it), in PerpVault.

## The liquidity: locked, its fees not

The position belongs to `IMD6900LockedPool`, which has no owner and no function that takes liquidity out to anyone:
it is as good as burned. What it earns isn't locked: `collect()` (or `harvest()` on the launch), anyone, any time.

## Red flags, and why there are none

Plain coin (nothing anyone can change), the liquidity locked by construction (no remove path exists), the hook not
upgradeable and owned by the timelock (24h), the opening buy in the same transaction as the pool (no snipe window), the
bought coins in a contract (the claims' reserve) or burned, never in a wallet. Owner powers left on the launch: the
claim list before the launch, releasing the unclaimed reserve after the claim deadline (≥ 90 days), the
IMDSTR the claims collected. The timelock (24h, public) wires the perps engine (an engine is called before every swap,
so it goes in only behind the delay), lowers the fee, sets the split, and can sell the coins the launch holds back for
the opening buy's ETH or end the claims early: each visible 24h before it runs.

## Tests

```sh
forge test                                         # 53 tests, offline: admission, the 0x6900 coin, launch, pool, fees, refunds, the fee's move (never with perps open), $IMD burn, claims, the ETH back; the perps (creation, code hash, longs, shorts, the sweep's liquidations, fees)
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract RobinhoodFork -vv
```

The fork test runs the whole thing on live Robinhood state: the real PoolManager, IMDSTR (claims after the timelock's
distributor op), the pot bridge, $IMD's pool and burn executor, buys through Uniswap's Universal Router, a move to
a 3.33% pool, and the timelock selling everything held back for ETH.

## Runbook: `script/launch.sh`

The contracts don't depend on Programmable: the last step decides between launching straight on Uniswap and launching
through Programmable (the same `launch()`, after their review, with their stamp and listing). Each step signs with the
team wallet's keystore (`imdstr-deployer`); `script/launch.sh status` shows where things stand.

1. `fund`: the Pons launcher's 2.83 ETH back to the team wallet.
2. `deploy`: the launch contract (its constructor creates the locked pool), or `use <addr>`: the swarm's.
   Then `hook`: the hook's salt mined for that address (`cast create2`), and `createHook(salt)`.
3. `claims`: the claim list from live balances capped at the snapshot (35 holders, ~63.9M), deadline in 120 days.
4. `timelock-24h` (once: the Robinhood timelock's delay from 12h to 24h, itself through the timelock), `queue-claims`,
   then `open-claims` one delay later: the timelock makes the launch an IMDSTR distributor.
5. `mine`: the coin's 0x6900… address for this launch.
6. Either `direct` (live on Uniswap in one transaction), or `programmable` (plan built from the exact source, packed with
   Programmable's packer, preflighted), `submit` (their manual review, up to 24h), `review`, then the team wallet signs
   `launch` in the approved 24h window, then the stamp.

7. Right after it: `perps` (the engine and vault, live at once). Then `pot` whenever fees have piled up (harvest, $IMD burn, bridge, Ethereum deposit); `recover` /
   `recover-exec` if the opening buy's ETH should come back.

Rehearsed end to end, both ways, on forks of Robinhood (`SIGN_ARGS="--unlocked --from <team>" RPC=<fork>`).
