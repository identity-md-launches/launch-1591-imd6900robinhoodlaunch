#!/usr/bin/env bash
# IMD6900 on Robinhood, step by step. The contracts don't depend on Programmable: once the launch contract is deployed
# the coin goes live either straight on Uniswap (`direct`, one transaction) or through Programmable (`programmable`,
# then `submit`: the same launch() after their review, with their stamp and listing). Decide at the last step.
#
#   script/launch.sh status        where everything stands
#   script/launch.sh fund          the Pons launcher's ETH (the old pool's 2.83) back to the team wallet
#   script/launch.sh deploy        the launch contract, from the team wallet (its constructor creates the pool)
#   script/launch.sh use <addr>    or adopt the one the IMD swarm deployed (checked: the team wallet's, this source, unlaunched)
#   script/launch.sh hook          the hook: its salt mined for this launch (cast create2), then createHook(salt)
#   script/launch.sh claims        the claim list (script/claims.py: live balances capped at the snapshot), deadline in 120 days
#   script/launch.sh queue-claims  queues the timelock's IMDSTR.setDistributor(<launch>, true): claims open one timelock delay later (24h once timelock-24h ran)
#   script/launch.sh open-claims   executes it once ready (anyone with the executor role; the team wallet has it)
#   script/launch.sh mine          the coin's 0x6900… address for this launch (PREFIX=69006900 for a longer one)
#   script/launch.sh timelock-24h  queues the Robinhood timelock's delay to 24h (through itself); run again to execute it
#   script/launch.sh perps         right after the launch: the perps engine and vault (the audited code, by hash),
#                                  owned by the timelock, wired into the hook at once (INSURANCE ETH, default 0.05)
#   script/launch.sh direct        launch() now: the coin, the locked pool, the opening buy (BUY_ETH, default 2.81)
#   script/launch.sh programmable  the Programmable plan for the same launch(): built, packed and preflighted
#   script/launch.sh submit        creates it on Programmable (their manual review starts), then `review` polls it
#   script/launch.sh review        the plan's state on Programmable, and its price drift (below)
#   script/launch.sh drift         where the plan's launch lands vs Ethereum's price now: its price is fixed when built
#   script/launch.sh pot           after the launch, the fees on their way (anyone may do each part): harvest (90% to
#                                  the pot bridge, 10% set aside for $IMD), burnImd (buys $IMD for IMD's canonical burn
#                                  executor), bridge (Robinhood -> Across -> Ethereum, from 0.05 ETH), then on Ethereum
#                                  depositBridgedFees (what Across delivered joins the NFT pot). ETH_RPC_URL for Ethereum.
#   script/launch.sh recover       after the launch, the opening buy's ETH back: queues on the timelock the sale of the coins
#                                  the launch holds (END_CLAIMS=1: the unclaimed reserve too, claims end) to the team wallet
#   script/launch.sh recover-exec  runs it once the timelock's delay is over
#
# Signs with the imdstr-deployer keystore (the team wallet); SIGN_ARGS="--unlocked --from <team>" on a fork.
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="${RPC:-${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}}"
if [ -n "${SIGN_ARGS:-}" ]; then read -r -a SIGN <<<"$SIGN_ARGS"; else SIGN=(--account imdstr-deployer); fi
TEAM=0x35dA9C0303507ddf708E87F2568EdDf12c47a059
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
IMDSTR=0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F
TL=0x16D3f65B708883DF042d98E1C7a49B32A33E2A14
PONS_LAUNCHER=0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0
POT_BRIDGE=0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd                   # Robinhood -> Across -> the pot hook on Ethereum
POT_HOOK=0xA16026A28aA581AA96713d20C608Da7F8db86444                     # Ethereum: depositBridgedFees() -> the NFT pot
WETH_ETHEREUM=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
ETH_RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
API=https://api.programmable.market/v4/chains/4663
PACKER=${PACKER:-$PWD/.programmable/request-packer.mjs}  # Programmable's own packer, fetched for the manifest below
STATE=${STATE:-launch.state}  # LAUNCH, SALT, TOKEN, PLAN_ID as they come
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
CLAIMS_SALT=$(cast keccak "imd6900-rh-launch-claims-1")
BUY_ETH="${BUY_ETH:-2.81}"
[ -f "$STATE" ] && source "$STATE"
save() { echo "$1=$2" >>"$STATE"; export "$1=$2"; }
c() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
tx() { cast send "$@" "${SIGN[@]}" --rpc-url "$RPC" >/dev/null; }
e() { python3 -c "print(f'{$1/1e18:.4f}')"; }
m() { python3 -c "print(f'{$1/1e24:.2f}M')"; }
claims_data() { cast calldata 'setDistributor(address,bool)' "$LAUNCH" true; }
claims_op() { c $TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' $IMDSTR 0 "$(claims_data)" $ZERO "$CLAIMS_SALT"; }
need() { [ -n "${!1:-}" ] || { echo "no $1 yet: run '$2' first"; exit 1; }; }
delay() { c $TL 'getMinDelay()(uint256)'; }  # the timelock's delay, read live (12h today, 24h after timelock-24h)
# launch() buys with every wei the launch holds: anything already there would push the price past Ethereum's
emptied() { [ "$(cast balance $LAUNCH --rpc-url "$RPC")" = 0 ] || { echo "the launch holds ETH already: the owner's withdrawEth first, so the buy is exactly params.py's"; exit 1; }; }
hooked() { [ "$(c $LAUNCH 'hook()(address)')" != 0x0000000000000000000000000000000000000000 ] || { echo "no hook yet: run 'hook' first"; exit 1; }; }
key() { security find-generic-password -s PROGRAMMABLE_API_KEY -w; }

case "${1:-status}" in
  status)
    echo "team wallet: $(e $(cast balance $TEAM --rpc-url "$RPC")) ETH · Pons launcher: $(e $(cast balance $PONS_LAUNCHER --rpc-url "$RPC")) ETH"
    if [ -z "${LAUNCH:-}" ]; then echo "launch: not deployed (deploy)"; exit 0; fi
    echo "launch $LAUNCH · pool $(c $LAUNCH 'pool()(address)') · hook $(c $LAUNCH 'hook()(address)')"
    echo "claims: $(m $(c $LAUNCH 'claimTotal()(uint256)')) · distributor op: $(c $TL 'isOperationDone(bytes32)(bool)' $(claims_op)) done, $(c $TL 'isOperationPending(bytes32)(bool)' $(claims_op)) pending"
    echo "coin: ${TOKEN:-not mined} · launched: $(c $LAUNCH 'token()(address)')"
    [ -n "${PLAN_ID:-}" ] && echo "Programmable plan: $PLAN_ID (review)"
    ;;
  fund)
    tx $PONS_LAUNCHER 'withdrawEth(address,uint256)' $TEAM 0 && echo "the Pons launcher's ETH is the team wallet's: $(e $(cast balance $TEAM --rpc-url "$RPC")) ETH"
    ;;
  deploy)
    [ -z "${LAUNCH:-}" ] || { echo "already deployed: $LAUNCH"; exit 0; }
    forge build --silent
    INIT=$(python3 -c "import json;print(json.load(open('out/IMD6900RobinhoodLaunch.sol/IMD6900RobinhoodLaunch.json'))['bytecode']['object'])")
    ARGS=$(cast abi-encode "f(address,address,address,address)" $TEAM $PM $IMDSTR $TL)
    L=$(cast send "${SIGN[@]}" --rpc-url "$RPC" --json --create "${INIT}${ARGS:2}" | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])")
    save LAUNCH "$(cast to-check-sum-address "$L")"
    echo "launch $LAUNCH · pool $(c $LAUNCH 'pool()(address)') · hook $(c $LAUNCH 'hook()(address)')"
    ;;
  use)
    [ -z "${LAUNCH:-}" ] || { echo "already using $LAUNCH"; exit 0; }
    L=$(cast to-check-sum-address "${2:?give the launch address the swarm deployed}")
    [ "$(c $L 'owner()(address)' | tr A-F a-f)" = "$(echo $TEAM | tr A-F a-f)" ] || { echo "$L isn't the team wallet's"; exit 1; }
    [ "$(c $L 'token()(address)')" = 0x0000000000000000000000000000000000000000 ] || { echo "$L has launched already"; exit 1; }
    forge build --silent
    WANT=$(python3 -c "import json;print(json.load(open('out/IMD6900LockedPool.sol/IMD6900LockedPool.json'))['deployedBytecode']['object'][:200])")
    [ "$(cast code $(c $L 'pool()(address)') --rpc-url "$RPC" | cut -c1-200)" = "$WANT" ] || echo "warning: its pool's code starts differently from this source (the swarm adapted it?): programmable will check every byte"
    save LAUNCH "$L"; echo "using the swarm's launch $LAUNCH · pool $(c $L 'pool()(address)') · hook $(c $L 'hook()(address)')"
    ;;
  hook)
    need LAUNCH deploy
    H=$(c $LAUNCH 'hook()(address)')
    [ "$H" = 0x0000000000000000000000000000000000000000 ] || { echo "hook: $H"; exit 0; }
    IH=$(c $LAUNCH 'hookInitCodeHash()(bytes32)')
    # the low 14 bits are the hook's permissions, FLAGS = 0x2ac0 (ending in 2ac0 also fixes the next two bits: 4x the
    # work, still instant); Uniswap reviews 0x91… hooks by hand, so those are mined again
    while :; do
      OUT=$(cast create2 --ends-with 2ac0 --deployer "$LAUNCH" --init-code-hash "$IH")
      A=$(echo "$OUT" | awk '/^Address:/{print $2}'); S=$(echo "$OUT" | awk '/^Salt:/{print $2}')
      [ "$(echo "$A" | cut -c3-4 | tr A-F a-f)" != 91 ] && break
    done
    tx $LAUNCH 'createHook(bytes32)' "$S" --gas-limit 2000000
    echo "hook $(c $LAUNCH 'hook()(address)') (salt $S)"
    ;;
  claims)
    need LAUNCH deploy
    ROBINHOOD_RPC_URL="$RPC" python3 script/claims.py --out claims.json
    ROOT=$(python3 -c "import json;print(json.load(open('claims.json'))['root'])"); TOTAL=$(python3 -c "import json;print(json.load(open('claims.json'))['total'])")
    NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
    tx $LAUNCH 'setClaims(bytes32,uint256,uint256)' $ROOT $TOTAL $((NOW + 120 * 86400)) && echo "claims set: $(m $TOTAL), until $(date -r $((NOW + 120 * 86400)))"
    ;;
  queue-claims)
    need LAUNCH deploy
    D=$(delay)
    tx $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $IMDSTR 0 "$(claims_data)" $ZERO "$CLAIMS_SALT" $D
    echo "queued $(claims_op): ready in $((D / 3600))h (open-claims)"
    ;;
  open-claims)
    need LAUNCH deploy
    [ "$(c $TL 'isOperationReady(bytes32)(bool)' $(claims_op))" = true ] || { echo "not ready yet"; exit 1; }
    tx $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $IMDSTR 0 "$(claims_data)" $ZERO "$CLAIMS_SALT" && echo "claims are open"
    ;;
  mine)
    need LAUNCH deploy
    OUT=$(RPC="$RPC" ROBINHOOD_RPC_URL="$RPC" LAUNCH=$LAUNCH script/mine.sh)
    save SALT "$(echo "$OUT" | awk '/^Salt:/{print $2}')"; save TOKEN "$(echo "$OUT" | awk '/^Address:/{print $2}')"
    echo "the coin will be $TOKEN"
    ;;
  direct)
    need LAUNCH deploy; need TOKEN mine; hooked; emptied
    [ "$(c $LAUNCH 'claimTotal()(uint256)')" != 0 ] || { echo "no claim list: run claims first"; exit 1; }
    python3 script/params.py --buy "$BUY_ETH" > params.json
    SP=$(python3 -c "import json;print(json.load(open('params.json'))['sqrtPriceX96'])"); MIN=$(python3 -c "import json;print(json.load(open('params.json'))['minBought'])"); V=$(python3 -c "import json;print(json.load(open('params.json'))['buyWei'])")
    echo "launching $TOKEN: $(python3 -c "import json;p=json.load(open('params.json'));print(f\"opens at {p['openMarketCapEth']:.2f} ETH market cap, buys with {int(p['buyWei'])/1e18:.4f} ETH, lands at {p['afterMarketCapEthOn1B']:.2f} (Ethereum's)\")")"
    tx $LAUNCH 'launch(bytes32,address,uint160,uint256,address)' $SALT $TOKEN $SP $MIN $LAUNCH --value $V --gas-limit 4000000
    echo "live: $(c $LAUNCH 'token()(address)') · bought $(m $(c $LAUNCH 'launchBought()(uint256)')) · kept for the timelock $(m $(c $LAUNCH 'excessHeld()(uint256)'))"
    ;;
  programmable)
    need LAUNCH deploy; need TOKEN mine; hooked; emptied
    if [ ! -f "$PACKER" ]; then mkdir -p "$(dirname "$PACKER")"; curl -sS -m 120 "$API/custom-launch-contract/request-packer.mjs" -o "$PACKER"; fi
    grep -q "sha256:3cd25308629f932d6a75e4a7694e6bcb67e4471fd2c1782d3b11ba5a7e3f8b61" "$PACKER" || { echo "the packer is for another manifest: refetch it and check the plan"; exit 1; }
    python3 script/params.py --buy "$BUY_ETH" > params.json
    cp params.json plan-params.json  # the price the plan is built with, for `drift`
    ROBINHOOD_RPC_URL="$RPC" python3 script/programmable_plan.py --launch $LAUNCH --salt $SALT --token $TOKEN --params params.json --excess-to $LAUNCH --out plan.json
    rm -f request.canonical.json pack-report.json
    node "$PACKER" --input "$PWD/plan.json" --out "$PWD/request.canonical.json" --report "$PWD/pack-report.json"
    python3 -c "import json; r=json.load(open('pack-report.json')); print('packed:', r['status'], len(r['findings']), 'findings')"
    curl -sS -m 300 -X POST "$API/custom-launch-plans:preflight" -H "Authorization: Bearer $(key)" -H "Content-Type: application/json" \
      -H "Programmable-Launch-Response-Version: 1.2" --data-binary @request.canonical.json -o preflight.json
    python3 -c "
import json; d=json.load(open('preflight.json')); f=d.get('findings',[])
print('preflight:', len(f), 'findings'); [print(' -', x.get('code'), x.get('jsonPointer'), json.dumps(x.get('constraint'))[:160]) for x in f]"
    ;;
  submit)
    [ -f request.canonical.json ] || { echo "run programmable first"; exit 1; }
    IK=$(python3 -c "import json;print(json.load(open('pack-report.json'))['idempotencyKey'])")
    curl -sS -m 300 -X POST "$API/custom-launch-plans" -H "Authorization: Bearer $(key)" -H "Content-Type: application/json" \
      -H "Programmable-Launch-Response-Version: 1.2" -H "Idempotency-Key: $IK" --data-binary @request.canonical.json -o submitted.json -w "HTTP %{http_code}\n"
    python3 -c "
import json; d=json.load(open('submitted.json')); print(json.dumps({k: d.get(k) for k in ('planId','id','launchId','status','manualReview','walletUrl','resumeUrl')}, indent=1))"
    ID=$(python3 -c "import json;d=json.load(open('submitted.json'));print(d.get('planId') or d.get('launchId') or d.get('id') or '')")
    [ -n "$ID" ] && save PLAN_ID "$ID"
    ;;
  drift)
    [ -f plan-params.json ] || { echo "no plan built yet (programmable)"; exit 1; }
    python3 script/params.py --buy "$BUY_ETH" > /tmp/params-now.json
    python3 - <<'PY'
import json
plan, now = json.load(open('plan-params.json')), json.load(open('/tmp/params-now.json'))
lands, target = plan['afterMarketCapEthOn1B'], now['targetMarketCapEthOn1B']
d = (lands / target - 1) * 100
print(f"the plan lands at {lands:.3f} ETH market cap (on 1B); Ethereum's price is {target:.3f} now: {d:+.2f}%")
print("fine: sign it" if abs(d) < 3 else "more than 3% off: a fresh plan (new review) or `direct` lands on today's price")
PY
    ;;
  review)
    need PLAN_ID submit
    curl -sS -m 120 "$API/custom-launch-plans/$PLAN_ID" -H "Authorization: Bearer $(key)" -H "Programmable-Launch-Response-Version: 1.2" -o review.json
    python3 -c "
import json; d=json.load(open('review.json')); print(json.dumps({k: d.get(k) for k in ('status','manualReview','walletUrl','continuation')}, indent=1)[:2000])"
    "$0" drift || true
    ;;
  timelock-24h)
    D=$(delay); [ "$D" -ge 86400 ] && { echo "the timelock's delay is already ${D}s"; exit 0; }
    UD=$(cast calldata 'updateDelay(uint256)' 86400); TS=$(cast keccak "imd6900-rh-timelock-24h")
    OP=$(c $TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' $TL 0 $UD $ZERO $TS)
    if [ "$(c $TL 'isOperation(bytes32)(bool)' $OP)" != true ]; then
      tx $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $TL 0 $UD $ZERO $TS $D
      echo "queued $OP: the timelock's delay to 24h, executable in $((D / 3600))h (run timelock-24h again then)"
    elif [ "$(c $TL 'isOperationReady(bytes32)(bool)' $OP)" = true ]; then
      tx $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $TL 0 $UD $ZERO $TS && echo "the timelock's delay is now $(delay)s"
    else echo "queued, not ready yet"; fi
    ;;
  perps)
    need LAUNCH deploy
    [ "$(c $LAUNCH 'token()(address)')" != 0x0000000000000000000000000000000000000000 ] || { echo "launch first: the engine binds to the live pool"; exit 1; }
    P=$(c $LAUNCH 'pool()(address)')
    E=$(c $P 'perpsEngine()(address)')
    [ "$E" = 0x0000000000000000000000000000000000000000 ] || { echo "perps: engine $E, vault $(c $P 'perpsVault()(address)')"; exit 0; }
    forge build --silent
    EC=$(python3 -c "import json;print(json.load(open('out/PerpEngine.sol/PerpEngine.json'))['bytecode']['object'])")
    VC=$(python3 -c "import json;print(json.load(open('out/PerpVault.sol/PerpVault.json'))['bytecode']['object'])")
    [ "$(cast keccak $EC)" = "$(c $P 'ENGINE_CODE_HASH()(bytes32)')" ] && [ "$(cast keccak $VC)" = "$(c $P 'VAULT_CODE_HASH()(bytes32)')" ] \
      || { echo "this checkout doesn't build the perps code the pool was deployed for: check out the launch's commit"; exit 1; }
    tx $P 'createPerps(bytes,bytes)' $EC $VC --value "${INSURANCE:-0.05}ether" --gas-limit 15000000
    E=$(c $P 'perpsEngine()(address)')
    echo "perps live: engine $E (owner $(c $E 'owner()(address)')), vault $(c $P 'perpsVault()(address)'); the hook serves $(c $(c $LAUNCH 'hook()(address)') 'perpEngine()(address)')"
    ;;
  pot)
    need LAUNCH deploy
    [ "$(c $LAUNCH 'token()(address)')" != 0x0000000000000000000000000000000000000000 ] || { echo "not launched yet"; exit 1; }
    POT0=$(cast balance $POT_BRIDGE --rpc-url "$RPC")
    tx $LAUNCH 'harvest()' && echo "harvested: pot bridge +$(e $(python3 -c "print($(cast balance $POT_BRIDGE --rpc-url "$RPC") - $POT0)")) ETH, \$IMD bucket $(e $(c $LAUNCH 'imdBucket()(uint256)')) ETH"
    if [ "$(c $LAUNCH 'imdBucket()(uint256)')" != 0 ]; then
      Q=$(cast call $LAUNCH 'burnImd(uint256)(uint256)' 0 --from $TEAM --rpc-url "$RPC" | awk '{print $1}')  # the buy's quote
      tx $LAUNCH 'burnImd(uint256)' $(python3 -c "print($Q * 97 // 100)") && echo "\$IMD to IMD's burn executor: ~$(e $Q) \$IMD"
    fi
    PEND=$(c $POT_BRIDGE 'pending()(uint256)')
    if python3 -c "import sys; sys.exit(0 if $PEND >= 5 * 10**16 else 1)"; then
      tx $POT_BRIDGE 'bridge()' && echo "bridged $(e $PEND) ETH to Ethereum (Across fills it in minutes)"
    else echo "pot bridge holds $(e $PEND) ETH: bridges from 0.05"; fi
    W=$(cast call $WETH_ETHEREUM 'balanceOf(address)(uint256)' $POT_HOOK --rpc-url "$ETH_RPC" | awk '{print $1}')
    if [ "$W" != 0 ]; then
      cast send $POT_HOOK 'depositBridgedFees()' "${SIGN[@]}" --rpc-url "$ETH_RPC" >/dev/null && echo "Ethereum: $(e $W) ETH into the NFT pot"
    else echo "Ethereum: nothing waiting at the pot hook"; fi
    ;;
  recover)
    need LAUNCH deploy
    [ "$(c $LAUNCH 'token()(address)')" != 0x0000000000000000000000000000000000000000 ] || { echo "not launched: the ETH is the team wallet's (withdrawEth if it was sent)"; exit 1; }
    HELD=$(c $LAUNCH 'excessHeld()(uint256)'); RESERVE=$(c $LAUNCH 'claimReserve()(uint256)')
    TARGETS="[$LAUNCH]"
    AMOUNT=$HELD
    if [ "${END_CLAIMS:-0}" = 1 ] && [ "$RESERVE" != 0 ]; then AMOUNT=$(python3 -c "print($HELD + $RESERVE)"); fi
    # the sale's quote at today's price (the position's one range, so a constant product; the sale is refunded, so
    # fee-free but for 4.44% cubed left held): the floor under it is
    # SLIPPAGE percent (default 5: the price moves during the delay; MIN_ETH sets it outright)
    read -r SQ _ LIQ < <(cast call $(c $LAUNCH 'pool()(address)') 'state()(uint160,int24,uint128)' --rpc-url "$RPC" | awk '{print $1}' | xargs)
    FEE=$(c $(c $LAUNCH 'pool()(address)') 'fee()(uint24)')
    QUOTE=$(python3 -c "
q=2**96; sq,l,dy=$SQ,$LIQ,$AMOUNT*(1-($FEE/1e6)**3); sq2=sq+dy*q/l; print(int(l*q*(sq2-sq)/(sq*sq2)))")  # fee-free: three refunded rounds
    MIN=${MIN_ETH:-$(python3 -c "print(int($QUOTE*(100-${SLIPPAGE:-5})/100))")}
    DATAS="[$(cast calldata 'sellHeld(uint256,uint256,address)' 0 $MIN $TEAM)]"
    if [ "${END_CLAIMS:-0}" = 1 ] && [ "$RESERVE" != 0 ]; then
      TARGETS="[$LAUNCH,$LAUNCH]"; DATAS="[$(cast calldata 'endClaims()'),$(cast calldata 'sellHeld(uint256,uint256,address)' 0 $MIN $TEAM)]"
    fi
    SALT=$(cast keccak "imd6900-rh-recover-$(date +%s)")
    tx $TL 'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)' "$TARGETS" "$(echo "$TARGETS" | sed -E 's/0x[0-9a-fA-F]{40}/0/g')" "$DATAS" $ZERO $SALT $(delay)
    save RECOVER_TARGETS "$TARGETS"; save RECOVER_DATAS "$DATAS"; save RECOVER_SALT "$SALT"
    echo "queued: sell $(m $AMOUNT) back for ~$(e $QUOTE) ETH today (floor $(e $MIN)) to the team wallet$([ "${END_CLAIMS:-0}" = 1 ] && echo ', claims ended first'); recover-exec in $(( $(delay) / 3600 ))h"
    ;;
  recover-exec)
    need RECOVER_SALT recover
    VALUES=$(echo "$RECOVER_TARGETS" | sed -E 's/0x[0-9a-fA-F]{40}/0/g')
    OP=$(c $TL 'hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)' "$RECOVER_TARGETS" "$VALUES" "$RECOVER_DATAS" $ZERO $RECOVER_SALT)
    [ "$(c $TL 'isOperationReady(bytes32)(bool)' $OP)" = true ] || { echo "not ready yet"; exit 1; }
    B0=$(cast balance $TEAM --rpc-url "$RPC")
    tx $TL 'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' "$RECOVER_TARGETS" "$VALUES" "$RECOVER_DATAS" $ZERO $RECOVER_SALT
    echo "back to the team wallet: $(e $(python3 -c "print($(cast balance $TEAM --rpc-url "$RPC") - $B0)")) ETH (less its gas)"
    ;;
  *) sed -n 2,31p "$0"; exit 1 ;;
esac
