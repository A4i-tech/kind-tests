#!/usr/bin/env bash
# e2e checks for SEEDS#374: bcrypt login, audit log cap and paging, website extract.
# usage: ./e2e374.sh [pr|base]   (pr asserts the PR behaviour, base only prints)
set -uo pipefail
MODE="${1:-pr}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="$HERE/.kube/seeds-kind.kubeconfig"
PORT=14000
B="http://127.0.0.1:$PORT"
fails=0
S0=$(date +%s)

kubectl -n seeds port-forward svc/seeds-platform-svc $PORT:4000 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -sf --max-time 2 "$B/health" >/dev/null && break; sleep 1; done

chk() { # name expected actual
  if [ "$MODE" = base ]; then echo "[base] $1 -> $3"; return; fi
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1 expected=$2 got=$3"; fails=$((fails+1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$@"; }

EMAIL="e2e$(date +%s)@test.local"; PW="E2e-pass-123"
T0=$(date +%s%N)
chk "register tenant" 201 "$(code -X POST "$B/tenant/register" -H 'content-type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"tenant_name\":\"e2e-org\",\"name\":\"e2e\"}")"
LOGIN=$(curl -s --max-time 60 -X POST "$B/auth/login" -H 'content-type: application/json' -d "{\"identifier\":\"$EMAIL\",\"password\":\"$PW\"}")
TOKEN=$(printf '%s' "$LOGIN" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
chk "login returns token" yes "$([ -n "$TOKEN" ] && echo yes || echo no)"
chk "login wrong password" 401 "$(code -X POST "$B/auth/login" -H 'content-type: application/json' -d "{\"identifier\":\"$EMAIL\",\"password\":\"wrong\"}")"
echo "auth round trips: $(( ($(date +%s%N)-T0)/1000000 ))ms"

H=(-H "authorization: Bearer $TOKEN" -H 'content-type: application/json')
mk() { python3 -c "
import json,sys
n=int(sys.argv[1]);print(json.dumps([{'user':'e2e-user','log_text':'row %d'%i,'time':'2026-01-01T00:00:00Z','priority':1} for i in range(n)]))" "$1"; }
chk "audit POST 120 entries rejected" 413 "$(code -X POST "$B/log" "${H[@]}" -d "$(mk 120)")"
chk "audit POST 5 entries ok" 200 "$(code -X POST "$B/log" "${H[@]}" -d "$(mk 5)")"
P1=$(curl -s --max-time 30 "$B/log/e2e-user?limit=2" "${H[@]}")
N1=$(printf '%s' "$P1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d))' 2>/dev/null)
LAST=$(printf '%s' "$P1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[-1].get("_id") or d[-1].get("id") or "")' 2>/dev/null)
chk "audit GET limit=2 page size" 2 "${N1:-err}"
N2=$(curl -s --max-time 30 "$B/log/e2e-user?limit=2&cursor=$LAST" "${H[@]}" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null)
chk "audit GET next page size" 2 "${N2:-err}"
chk "audit GET bad cursor" 422 "$(code "$B/log/e2e-user?cursor=notanid" "${H[@]}")"

chk "website extract example.com" 200 "$(code -X POST "$B/content/extract-website" "${H[@]}" -d '{"url":"https://example.com"}')"

echo "e2e total: $(( $(date +%s)-S0 ))s  mode=$MODE fails=$fails"
[ "$MODE" = base ] || [ "$fails" -eq 0 ]
