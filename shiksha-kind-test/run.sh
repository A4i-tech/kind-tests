#!/usr/bin/env bash
# Local kind-cluster health/regression check for the shiksha app stack
# (infra-ops/partners/shiksha) — run this on any change touching
# api/be/fe-deployment.yaml, kustomization.yaml, network-policy.yaml, etc.
#
# Deploys api/be/fe from infra-ops, minus ExternalSecret/Certificate/Ingress
# (their CRDs / controller aren't in kind — use port-forward instead).
# be/api/fe secrets are cloned from local JSON files, never a live Key Vault
# read. Mongo Atlas is swapped for a local mongod seeded from a mongodump zip,
# since Atlas isn't reachable from this sandbox's egress.
#
# Isolation: this script uses its OWN kubeconfig file (.kubeconfig-kind,
# next to this script), never ~/.kube/config. kind normally merges into
# and flips current-context in the default kubeconfig — shared mutable
# state that a parallel `az aks get-credentials` / kubectl in another
# shell can flip mid-run. With its own kubeconfig, this script can run
# fully in parallel with normal kube-dev kubectl work in another shell.
#
# Usage: ./run.sh <cmd>
#   up           create kind cluster (idempotent, auto-installs kind)
#   secrets      clone be/api/fe secrets from local JSON files -> k8s Secrets
#   mongo        deploy standalone mongo + restore dump into it
#   rewire-mongo point be's MONGO_URL at the local mongo, restart be
#   deploy       git checkout SHIKSHA_BRANCH in SHIKSHA_REPO_DIR, build+filter kustomize output, apply
#   forward      port-forward shiksha-fe-svc:80 -> localhost:8000 (foreground)
#   test         smoke test: fe serves, placeholder patched, /api proxies
#   login-test   full OTP login (get-otp + validate-otp) against restored data
#   status       pods/svc/logs snapshot
#   kubectl      passthrough to kubectl, isolated kubeconfig guaranteed (see cmd_kubectl)
#   down         delete the kind cluster, clean up local state
#   all          up + secrets + mongo + rewire-mongo + deploy + status
#
# Env overrides: SHIKSHA_REPO_DIR, SHIKSHA_BRANCH, SHIKSHA_SECRETS_DIR,
#                MONGO_DUMP_ZIP, MONGO_DB, TEST_PHONE, TEST_PIN
set -euo pipefail

CLUSTER=shiksha-local
NS=shiksha
SHIKSHA_REPO_DIR="${SHIKSHA_REPO_DIR:-$HOME/infra-ops}"
SHIKSHA_BRANCH="${SHIKSHA_BRANCH:-a4i/main}"
SECRETS_DIR="${SHIKSHA_SECRETS_DIR:-$HOME/backup/shiksha-staging}"
MONGO_DUMP_ZIP="${MONGO_DUMP_ZIP:-$HOME/shiksha-backend-dump.zip}"
MONGO_DB="${MONGO_DB:-shiksha-backend}"
TEST_PHONE="${TEST_PHONE:-9999999999}"
TEST_PIN="${TEST_PIN:-7476}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTERED="$HERE/.shiksha-kind-filtered.yaml"
mkdir -p "$HERE/tools"
export PATH="$HERE/tools:$PATH"

# isolated kubeconfig — see header. Every kubectl/kind call this script
# makes uses only this file; ~/.kube/config and its current-context are
# never read or written, so this can't collide with normal kube-dev work.
export KUBECONFIG="$HERE/.kubeconfig-kind"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }

# defense-in-depth: even against our own isolated kubeconfig, confirm it
# actually points at the kind sandbox before any mutating step.
assert_kind_context() {
  need kubectl
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [ "$ctx" != "kind-$CLUSTER" ]; then
    echo "REFUSING: kubectl context is '$ctx', expected 'kind-$CLUSTER'." >&2
    echo "Run './run.sh up' first." >&2
    exit 1
  fi
}

cmd_up() {
  need docker
  if ! command -v kind >/dev/null; then
    echo "installing kind v0.24.0 to $HERE/tools/kind ..."
    curl -fsSL -o "$HERE/tools/kind" https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
    chmod +x "$HERE/tools/kind"
  fi
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "kind cluster '$CLUSTER' already up — (re)exporting into isolated kubeconfig"
    kind export kubeconfig --name "$CLUSTER"
  else
    kind create cluster --name "$CLUSTER"
  fi
  kubectl config use-context "kind-$CLUSTER"
}

# strip kinds whose CRDs aren't in kind (ExternalSecret, Certificate) and
# the fe Ingress (no controller here — port-forward instead)
filter_manifests() {
  python3 - "$1" "$FILTERED" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
skip = {"ExternalSecret", "Certificate", "Ingress"}
with open(src) as f:
    docs = [d for d in yaml.safe_load_all(f) if d and d.get("kind") not in skip]
with open(dst, "w") as f:
    yaml.safe_dump_all(docs, f)
print(f"kept {len(docs)} resources -> {dst}")
PY
}

# checks out SHIKSHA_BRANCH in SHIKSHA_REPO_DIR before building manifests —
# override SHIKSHA_BRANCH= to test a feature branch without a second clone.
# Mutates the checkout's working tree, so refuses if it's dirty.
checkout_repo_branch() {
  need git
  [ -z "$(git -C "$SHIKSHA_REPO_DIR" status --porcelain)" ] \
    || { echo "REFUSING: $SHIKSHA_REPO_DIR has uncommitted changes, this does a hard reset." >&2; exit 1; }
  echo "checking out $SHIKSHA_BRANCH in $SHIKSHA_REPO_DIR ..."
  git -C "$SHIKSHA_REPO_DIR" fetch origin "$SHIKSHA_BRANCH"
  git -C "$SHIKSHA_REPO_DIR" checkout "$SHIKSHA_BRANCH"
  git -C "$SHIKSHA_REPO_DIR" reset --hard "origin/$SHIKSHA_BRANCH"
}

cmd_deploy() {
  assert_kind_context
  checkout_repo_branch
  kubectl kustomize "$SHIKSHA_REPO_DIR/partners/shiksha" > "$HERE/.shiksha-kind-raw.yaml"
  filter_manifests "$HERE/.shiksha-kind-raw.yaml"
  kubectl apply -f "$FILTERED"
  echo "waiting for rollouts (be/api may crashloop until 'mongo'+'rewire-mongo' have run)..."
  kubectl -n "$NS" rollout status deploy/shiksha-fe --timeout=120s || true
  kubectl -n "$NS" rollout status deploy/shiksha-be --timeout=60s || true
  kubectl -n "$NS" rollout status deploy/shiksha-api --timeout=60s || true
}

# clones real-shaped secret blobs from local JSON (SECRETS_DIR) so be/api/fe
# get real-shaped env (LLM_API_BASE_URL etc), never a live Key Vault read.
# File names mirror each *-externalsecret.yaml's remoteRef.key.
cmd_secrets() {
  need python3
  assert_kind_context
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  for pair in shiksha-be-secret=shiksha-be-dev-secret shiksha-api-secret=shiksha-api-dev-secret; do
    target="${pair%%=*}"; file="$SECRETS_DIR/${pair#*=}.json"
    [ -f "$file" ] || { echo "missing secrets file: $file (set SHIKSHA_SECRETS_DIR)" >&2; exit 1; }
    echo "cloning $target from $file ..."
    args=()
    while IFS="=" read -r k v; do
      [ -n "$k" ] && args+=(--from-literal="$k=$v")
    done < <(python3 -c "import json; d=json.load(open('$file')); [print(f'{k}={v}') for k,v in d.items()]")
    kubectl -n "$NS" create secret generic "$target" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
  done

  # fe's ExternalSecret only selects 5 keys out of be's KV blob (see
  # fe-externalsecret.yaml `data:` list) — mirror that selection. A key
  # missing from an older local blob becomes an empty string, not a crash.
  fe_file="$SECRETS_DIR/shiksha-be-dev-secret.json"
  echo "cloning shiksha-fe-secret (selective keys from $fe_file) ..."
  args=()
  for key in BACKEND_URL TURNSTILE_SITE_KEY SUPERSET_URL SUPERSET_DASHBOARD_UUID SUPERSET_MOBILE_DASHBOARD_UUID; do
    v=$(python3 -c "import json; print(json.load(open('$fe_file')).get('$key', ''))")
    args+=(--from-literal="$key=$v")
  done
  kubectl -n "$NS" create secret generic shiksha-fe-secret "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

# standalone mongod (test-only, no auth) + mongorestore from a mongodump zip.
# LimitRange in the namespace defaults containers to 512Mi — too little for
# mongod+mongorestore together, so this pod gets an explicit 2Gi override.
cmd_mongo() {
  need unzip
  assert_kind_context
  [ -f "$MONGO_DUMP_ZIP" ] || { echo "dump zip not found: $MONGO_DUMP_ZIP" >&2; exit 1; }
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shiksha-mongo
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels: {app: shiksha-mongo}
  template:
    metadata:
      labels: {app: shiksha-mongo}
    spec:
      containers:
        - name: mongo
          image: mongo:6
          ports: [{containerPort: 27017}]
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {cpu: "1", memory: 2Gi}
          volumeMounts: [{name: data, mountPath: /data/db}]
      volumes: [{name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: shiksha-mongo, namespace: $NS}
spec:
  selector: {app: shiksha-mongo}
  ports: [{port: 27017, targetPort: 27017}]
EOF
  kubectl -n "$NS" rollout status deploy/shiksha-mongo --timeout=120s

  rm -rf "$HERE/.mongo-dump" && mkdir -p "$HERE/.mongo-dump"
  # unzip exits 1 for harmless warnings (e.g. backslash path separators) even
  # when extraction succeeds — only treat >=2 as a real failure.
  unzip -o -q "$MONGO_DUMP_ZIP" -d "$HERE/.mongo-dump" || [ $? -eq 1 ]
  dumpdir=$(find "$HERE/.mongo-dump" -maxdepth 2 -type d -name "$MONGO_DB")
  [ -n "$dumpdir" ] || { echo "no $MONGO_DB/ dir found in $MONGO_DUMP_ZIP" >&2; exit 1; }

  pod=$(kubectl -n "$NS" get pod -l app=shiksha-mongo -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$NS" cp "$dumpdir" "$pod":/tmp/dump
  kubectl -n "$NS" exec "$pod" -- mongorestore --db "$MONGO_DB" --dir /tmp/dump --drop --numInsertionWorkersPerCollection=1
}

cmd_rewire_mongo() {
  assert_kind_context
  local url="mongodb://shiksha-mongo.$NS.svc.cluster.local:27017/$MONGO_DB"
  kubectl -n "$NS" get secret shiksha-be-secret -o json | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
d['data']['MONGO_URL'] = base64.b64encode('$url'.encode()).decode()
print(json.dumps(d))
" | kubectl apply -f -
  kubectl -n "$NS" rollout restart deploy/shiksha-be
  kubectl -n "$NS" rollout status deploy/shiksha-be --timeout=90s
}

cmd_forward() {
  assert_kind_context
  echo "http://localhost:8000  (ctrl-c to stop)"
  kubectl -n "$NS" port-forward svc/shiksha-fe-svc 8000:80
}

# run in a second shell while `forward` is running in the first
cmd_test() {
  echo "--- fe serves index ---"
  curl -sf -o /dev/null -w '%{http_code}\n' http://localhost:8000/ || echo "FAIL: fe not reachable"
  echo "--- env.js rendered, no leftover \${...} placeholders ---"
  envjs=$(curl -sf http://localhost:8000/assets/env.js) || { echo "FAIL: env.js not reachable"; envjs=""; }
  if echo "$envjs" | grep -q '\${'; then
    echo "FAIL: unsubstituted \${...} placeholder in env.js"
  elif echo "$envjs" | grep -q '"/api"'; then
    echo "OK: env.js rendered (apiUrl=/api)"
  else
    echo "FAIL: apiUrl not set to /api in env.js"
  fi
  echo "--- /api/* reaches be through nginx (JSON body = proxied, not fe's SPA index.html fallback) ---"
  ctype=$(curl -s -D - -o /dev/null http://localhost:8000/api/auth/me | grep -i '^content-type:')
  echo "$ctype" | grep -qi 'json' \
    && echo "OK: proxied ($ctype)" || echo "FAIL: not JSON ($ctype) — proxy not firing, fell through to SPA fallback"
}

cmd_login_test() {
  echo "--- get-otp ($TEST_PHONE) ---"
  curl -s -X POST http://localhost:8000/api/auth/get-otp \
    -H 'Content-Type: application/json' -d "{\"phone\":\"$TEST_PHONE\"}"
  echo
  echo "--- validate-otp (pin $TEST_PIN) ---"
  resp=$(curl -s -X POST http://localhost:8000/api/auth/validate-otp \
    -H 'Content-Type: application/json' -d "{\"phone\":\"$TEST_PHONE\",\"otp\":\"$TEST_PIN\"}")
  echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print('OK: got token' if d.get('data',{}).get('user',{}).get('token') or 'token' in str(d) else 'response:', d.get('message'))" 2>/dev/null \
    || echo "$resp"
}

cmd_status() {
  assert_kind_context
  kubectl -n "$NS" get pods,svc
  echo "--- fe container log (env.js render + nginx start) ---"
  kubectl -n "$NS" logs deploy/shiksha-fe -c shiksha-fe --tail=20 2>&1 || true
}

# Safe passthrough for arbitrary kubectl calls — guaranteed to use this
# script's isolated kubeconfig and refuse if that kubeconfig's context
# somehow isn't the kind sandbox.
#   ./run.sh kubectl -n shiksha get pods
cmd_kubectl() {
  assert_kind_context
  kubectl "$@"
}

cmd_down() {
  kind delete cluster --name "$CLUSTER" 2>/dev/null || true
  rm -rf "$HERE/.mongo-dump" "$HERE/.kubeconfig-kind" "$HERE/.shiksha-kind-raw.yaml" "$FILTERED"
}

case "${1:-}" in
  up) cmd_up ;;
  secrets) cmd_secrets ;;
  mongo) cmd_mongo ;;
  rewire-mongo) cmd_rewire_mongo ;;
  deploy) cmd_deploy ;;
  forward) cmd_forward ;;
  test) cmd_test ;;
  login-test) cmd_login_test ;;
  status) cmd_status ;;
  kubectl) shift; cmd_kubectl "$@" ;;
  down) cmd_down ;;
  all) cmd_up; cmd_secrets; cmd_mongo; cmd_deploy; cmd_rewire_mongo; cmd_status ;;
  *) echo "usage: $0 {up|secrets|mongo|rewire-mongo|deploy|forward|test|login-test|status|kubectl|down|all}"; exit 1 ;;
esac
