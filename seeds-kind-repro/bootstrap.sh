#!/usr/bin/env bash
# SEEDS full-stack local test cluster on kind (WSL friendly).
#
# Brings up ALL FOUR SEEDS components in a throwaway kind cluster:
#     seeds-platform          (API,        :4000)
#     seeds-websocket-service  (websocket,  :3000)
#     seeds-content-webapp     (static UI,  :8080)
#     seeds-teacher-webapp     (static UI,  :8080)
# wired to the real staging config, with DEBUG logging on, reachable over
# ingress on *.local hosts.
#
# Purpose: test a feature branch end to end before merging, without the shared
# cluster or Render. Point one component at your branch image with `load`.
#
# Isolation: uses its OWN kubeconfig file inside this directory. It never reads
# or writes ~/.kube/config and never changes your current kubectl context.
#
# Usage:
#   ./bootstrap.sh up                       # all 4 at :staging (override tag: SEEDS_TAG=... )
#   ./bootstrap.sh load platform <image>    # run YOUR branch build for one component
#   ./bootstrap.sh logs [comp]              # live-tail to terminal AND ./logs/seeds-<comp>-<ts>.log
#   ./bootstrap.sh dump [comp]              # full log history -> ./logs/seeds-<comp>-full-<ts>.log
#   ./bootstrap.sh status                   # pods, images, ingress hosts
#   ./bootstrap.sh sh [comp]                # shell into a pod
#   ./bootstrap.sh restart [comp]           # rollout restart
#   ./bootstrap.sh mongo-url <block_source_id>   # stored video URL for a block (reads staging Mongo)
#   ./bootstrap.sh check-url '<sas url>'         # curl a blob SAS URL, show status + Azure error
#   ./bootstrap.sh mongo                    # local mongo:7 pod, mongorestore from ./.mongo-dump-source
#   ./bootstrap.sh rewire-mongo             # point platform's DB_CONNECTION at local mongo, restart it
#   ./bootstrap.sh down                     # delete the cluster + local kubeconfig
#
# Local mongo (Atlas unreachable here): run `up`, `mongo`, `rewire-mongo` in order.
# Re-running `up` undoes the rewire, so run `rewire-mongo` again after it.
# Dump dir override: SEEDS_MONGO_DUMP_DIR=... (must contain SEEDS-Teacher-Backend-Platform/)
#
# Secrets always come from local JSON files, never a live Key Vault read — see SECRETS_DIR.
# Prereqs on PATH: docker, kubectl, python3, curl.  kind auto-downloads into ./.bin

set -uo pipefail

# ----------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="seeds-repro"
KUBECONFIG_FILE="$HERE/.kube/seeds-kind.kubeconfig"
NS="seeds"
SECRETS_DIR="${SEEDS_SECRETS_DIR:-$HOME/backup/seeds-staging}"
TAG="${SEEDS_TAG:-staging}"       # default image tag for all components
HOST_HTTP_PORT="${SEEDS_HTTP_PORT:-8080}"
HOST_HTTPS_PORT="${SEEDS_HTTPS_PORT:-8443}"
MONGO_DUMP_DIR="${SEEDS_MONGO_DUMP_DIR:-$HERE/.mongo-dump-source}"
MONGO_DB="SEEDS-Teacher-Backend-Platform"

COMPONENTS=(platform websocket-service content-webapp teacher-webapp)

declare -A K8S_SECRET=(
  [platform]=seeds-platform-secret
  [websocket-service]=seeds-websocket-secret
  [content-webapp]=seeds-content-webapp-secret
  [teacher-webapp]=seeds-teacher-webapp-secret
)
declare -A PORT=(
  [platform]=4000
  [websocket-service]=3000
  [content-webapp]=8080
  [teacher-webapp]=8080
)
declare -A HOSTNAME_=(
  [platform]=seeds.local
  [websocket-service]=websocket.local
  [content-webapp]=content-webapp.local
  [teacher-webapp]=teacher-webapp.local
)
# per-component image override, e.g. SEEDS_PLATFORM_IMAGE=... SEEDS_CONTENT_WEBAPP_IMAGE=...
img_for() {
  local comp="$1" var
  var="SEEDS_$(echo "$comp" | tr 'a-z-' 'A-Z_')_IMAGE"
  echo "${!var:-ghcr.io/a4i-tech/seeds/$comp:$TAG}"
}

export KUBECONFIG="$KUBECONFIG_FILE"
kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing prereq: $1"; }

KIND_VERSION="v0.23.0"
KIND=""
setup_kind() {
  KIND="$(command -v kind 2>/dev/null || true)"
  [[ -n "$KIND" ]] && return
  KIND="$HERE/.bin/kind"
  if [[ ! -x "$KIND" ]]; then
    echo ">> kind not on PATH, downloading $KIND_VERSION into .bin/"
    mkdir -p "$HERE/.bin"
    local arch; arch="$(uname -m)"; [[ "$arch" == "aarch64" ]] && arch=arm64 || arch=amd64
    curl -fsSLo "$KIND" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}" || die "kind download failed"
    chmod +x "$KIND"
  fi
}

preflight() {
  for t in docker kubectl python3 curl; do need "$t"; done
  docker info >/dev/null 2>&1 || die "docker not running (WSL: start Docker Desktop or 'sudo service docker start')"
  [[ -d "$SECRETS_DIR" ]] || die "secrets dir not found: $SECRETS_DIR (set SEEDS_SECRETS_DIR)"
  for c in "${COMPONENTS[@]}"; do
    [[ -f "$SECRETS_DIR/${K8S_SECRET[$c]}.json" ]] || die "missing secret file: $SECRETS_DIR/${K8S_SECRET[$c]}.json"
  done
  setup_kind
}

# ----------------------------------------------------------------------------
read_blob() {
  cat "$SECRETS_DIR/${K8S_SECRET[$1]}.json"
}

make_secret() {
  local comp="$1" k8sname="${K8S_SECRET[$1]}"
  echo ">> secret $k8sname  <-  $SECRETS_DIR/$k8sname.json"
  read_blob "$comp" | K8S_NAME="$k8sname" NS="$NS" COMP="$comp" python3 -c '
import json, os, sys
name, ns, comp = os.environ["K8S_NAME"], os.environ["NS"], os.environ["COMP"]
data = json.load(sys.stdin)
data["ENV"] = "development"                       # verbose logging + permissive CORS
data.setdefault("LOG_LEVEL", "debug")
data.setdefault("LOGLEVEL", "debug")
if comp == "platform":
    # this script names the websocket Service seeds-websocket-service-svc
    # (seeds-$comp-svc), but the real secret carries seeds-websocket-svc
    # (the real clusters name). Fix it here so platform can actually reach
    # it, otherwise its startup blocks on the connection and it never binds.
    data["WEBSOCKET_SERVICE_URL"] = f"ws://seeds-websocket-service-svc.{ns}.svc.cluster.local:3000"
sd = {k: ("" if v is None else v if isinstance(v, str) else json.dumps(v)) for k, v in data.items()}
print(json.dumps({
  "apiVersion": "v1", "kind": "Secret",
  "metadata": {"name": name, "namespace": ns},
  "type": "Opaque", "stringData": sd}))
' | kc apply -f - || die "could not build/apply $k8sname"
}

deploy_component() {
  local comp="$1" image; image="$(img_for "$comp")"
  echo ">> deploy seeds-$comp  image=$image"
  cat <<YAML | kc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seeds-$comp
  namespace: $NS
  labels: { app: seeds-$comp }
spec:
  replicas: 1
  selector: { matchLabels: { app: seeds-$comp } }
  template:
    metadata: { labels: { app: seeds-$comp } }
    spec:
      containers:
        - name: seeds-$comp
          image: $image
          imagePullPolicy: Always
          ports: [{ containerPort: ${PORT[$comp]} }]
          envFrom:
            - secretRef: { name: ${K8S_SECRET[$comp]} }
---
apiVersion: v1
kind: Service
metadata: { name: seeds-$comp-svc, namespace: $NS }
spec:
  selector: { app: seeds-$comp }
  ports: [{ port: ${PORT[$comp]}, targetPort: ${PORT[$comp]} }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: seeds-$comp
  namespace: $NS
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
spec:
  ingressClassName: nginx
  rules:
    - host: ${HOSTNAME_[$comp]}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: seeds-$comp-svc, port: { number: ${PORT[$comp]} } } }
YAML
}

# ----------------------------------------------------------------------------
cmd_up() {
  [[ $# -eq 0 ]] || die "unknown flag: $1"
  preflight
  mkdir -p "$(dirname "$KUBECONFIG_FILE")"

  if "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo ">> kind cluster '$CLUSTER_NAME' exists, reusing"
    [[ -f "$KUBECONFIG_FILE" ]] || "$KIND" export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE"
  else
    echo ">> creating kind cluster '$CLUSTER_NAME' (http:$HOST_HTTP_PORT https:$HOST_HTTPS_PORT)"
    cat <<KIND | "$KIND" create cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80,  hostPort: $HOST_HTTP_PORT,  protocol: TCP }
      - { containerPort: 443, hostPort: $HOST_HTTPS_PORT, protocol: TCP }
KIND
    [[ -f "$KUBECONFIG_FILE" ]] || die "kind cluster creation failed"
  fi

  kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f -

  echo ">> installing ingress-nginx for kind"
  kc apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
  kc -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s || true

  for c in "${COMPONENTS[@]}"; do
    make_secret "$c"
    deploy_component "$c"
  done

  echo ">> waiting for rollouts"
  for c in "${COMPONENTS[@]}"; do
    kc -n "$NS" rollout status deploy/seeds-"$c" --timeout=240s || true
  done

  cmd_status
  cat <<EOF

------------------------------------------------------------------
Add to your hosts file (WSL: C:\\Windows\\System32\\drivers\\etc\\hosts, edit as admin):

  127.0.0.1  seeds.local websocket.local content-webapp.local teacher-webapp.local

Then:
  API      http://seeds.local:$HOST_HTTP_PORT/health
  content  http://content-webapp.local:$HOST_HTTP_PORT
  teacher  http://teacher-webapp.local:$HOST_HTTP_PORT

Run your feature branch for one component:
  docker build -t seeds-platform:mybranch  <path to platform>
  ./bootstrap.sh load platform seeds-platform:mybranch

Logs:      ./bootstrap.sh logs            (also writes ./logs/*.log)
Teardown:  ./bootstrap.sh down
------------------------------------------------------------------
EOF
}

cmd_load() {
  local comp="${1:?usage: bootstrap.sh load <component> <image-ref>}"
  local ref="${2:?usage: bootstrap.sh load <component> <image-ref>}"
  [[ " ${COMPONENTS[*]} " == *" $comp "* ]] || die "unknown component: $comp (one of: ${COMPONENTS[*]})"
  setup_kind
  echo ">> loading $ref into kind cluster '$CLUSTER_NAME'"
  "$KIND" load docker-image "$ref" --name "$CLUSTER_NAME" || die "kind load failed (is the image built locally?)"
  kc -n "$NS" set image deploy/seeds-"$comp" seeds-"$comp"="$ref"
  kc -n "$NS" patch deploy/seeds-"$comp" --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kc -n "$NS" rollout status deploy/seeds-"$comp" --timeout=240s || true
  echo ">> seeds-$comp now running $ref"
}

cmd_status() {
  echo "=== pods ==="
  kc -n "$NS" get pods -o wide 2>&1
  echo "=== images ==="
  for c in "${COMPONENTS[@]}"; do
    printf "  %-20s %s\n" "$c" "$(kc -n "$NS" get deploy seeds-"$c" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  done
  echo "=== ingress ==="
  kc -n "$NS" get ingress 2>&1
}

cmd_logs() {
  local comp="${1:-platform}"
  mkdir -p "$HERE/logs"
  local f="$HERE/logs/seeds-${comp}-$(date +%Y%m%d-%H%M%S).log"
  echo ">> live tail seeds-$comp (Ctrl-C to stop). Also writing: $f"
  echo "------------------------------------------------------------------"
  kc -n "$NS" logs -f deploy/seeds-"$comp" --tail=200 2>&1 | tee -a "$f"
}

cmd_dump() {
  local comp="${1:-platform}"
  mkdir -p "$HERE/logs"
  local f="$HERE/logs/seeds-${comp}-full-$(date +%Y%m%d-%H%M%S).log"
  kc -n "$NS" logs deploy/seeds-"$comp" --tail=-1 > "$f" 2>&1
  echo ">> $(wc -l < "$f") lines -> $f"
}

cmd_sh()      { kc -n "$NS" exec -it deploy/seeds-"${1:-platform}" -- sh; }
cmd_restart() {
  if [[ -n "${1:-}" ]]; then kc -n "$NS" rollout restart deploy/seeds-"$1"
  else for c in "${COMPONENTS[@]}"; do kc -n "$NS" rollout restart deploy/seeds-"$c"; done; fi
}

cmd_mongo_url() {
  local block="${1:?usage: bootstrap.sh mongo-url <block_source_id>}"
  local mongo
  mongo="$(read_blob platform | python3 -c 'import json,sys;print(json.load(sys.stdin)["DB_CONNECTION"])')" \
    || die "could not read DB_CONNECTION"
  echo ">> staging Mongo (read only), block $block"
  docker run --rm mongo:7 mongosh "$mongo" --quiet --eval '
    const db = db.getSiblingDB("SEEDS-Teacher-Backend-Platform");
    const d = db.getCollection("contentAggregators").findOne({source_id: "'"$block"'"});
    if (!d) { print("not found"); quit(1); }
    print("fetched_at: " + d.fetched_at);
    print("content: " + JSON.stringify(d.content));
  '
}

cmd_check_url() {
  local url="${1:?usage: bootstrap.sh check-url \"<blob sas url>\"}"
  echo ">> $url"
  curl -s -o /dev/null -w "status: %{http_code}\ncontent-type: %{content_type}\nbytes: %{size_download}\n" "$url"
  echo ">> body:"
  curl -s "$url" | head -c 900; echo
}

# standalone mongod (test only, no auth) seeded from the local staging mongodump.
# Same idea as shiksha-kind-test/run.sh: kubectl cp the dump in, mongorestore it.
cmd_mongo() {
  local dumpdir="$MONGO_DUMP_DIR/$MONGO_DB" pod
  [[ -d "$dumpdir" ]] || die "dump not found: $dumpdir (set SEEDS_MONGO_DUMP_DIR)"
  kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f -
  echo ">> deploy seeds-mongo  image=mongo:7"
  cat <<YAML | kc apply -f - || die "could not apply seeds-mongo"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seeds-mongo
  namespace: $NS
  labels: { app: seeds-mongo }
spec:
  replicas: 1
  selector: { matchLabels: { app: seeds-mongo } }
  template:
    metadata: { labels: { app: seeds-mongo } }
    spec:
      containers:
        - name: mongo
          image: mongo:7
          ports: [{ containerPort: 27017 }]
          readinessProbe:
            exec: { command: [mongosh, --quiet, --eval, "db.adminCommand('ping')"] }
            periodSeconds: 5
          volumeMounts: [{ name: data, mountPath: /data/db }]
      volumes: [{ name: data, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata: { name: seeds-mongo, namespace: $NS }
spec:
  selector: { app: seeds-mongo }
  ports: [{ port: 27017, targetPort: 27017 }]
YAML
  kc -n "$NS" rollout status deploy/seeds-mongo --timeout=180s || die "seeds-mongo not ready"

  pod="$(kc -n "$NS" get pod -l app=seeds-mongo -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || die "no seeds-mongo pod"
  echo ">> copying $dumpdir -> $pod:/tmp/dump ($(du -sh "$dumpdir" | cut -f1))"
  # clear first, else a re-run nests the copy under /tmp/dump/$MONGO_DB
  kc -n "$NS" exec "$pod" -- rm -rf /tmp/dump
  kc -n "$NS" cp "$dumpdir" "$pod":/tmp/dump || die "kubectl cp failed"
  echo ">> mongorestore into $MONGO_DB"
  kc -n "$NS" exec "$pod" -- mongorestore --db "$MONGO_DB" --dir /tmp/dump --drop --numInsertionWorkersPerCollection=1 \
    || die "mongorestore failed"
  echo ">> seeds-mongo ready at mongodb://seeds-mongo.$NS.svc.cluster.local:27017/$MONGO_DB"
}

cmd_rewire_mongo() {
  local url="mongodb://seeds-mongo.$NS.svc.cluster.local:27017/$MONGO_DB" k8sname="${K8S_SECRET[platform]}"
  echo ">> $k8sname DB_CONNECTION -> $url"
  kc -n "$NS" get secret "$k8sname" -o json | URL="$url" python3 -c '
import base64, json, os, sys
d = json.load(sys.stdin)
d["data"]["DB_CONNECTION"] = base64.b64encode(os.environ["URL"].encode()).decode()
print(json.dumps(d))
' | kc apply -f - || die "could not patch $k8sname"
  kc -n "$NS" rollout restart deploy/seeds-platform
  kc -n "$NS" rollout status deploy/seeds-platform --timeout=240s || true
}

cmd_down() {
  setup_kind
  "$KIND" delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE"
  rm -f "$KUBECONFIG_FILE"
  echo ">> cluster + local kubeconfig removed. ~/.kube/config untouched. ./logs and ./.bin kept."
}

case "${1:-}" in
  up)        shift; cmd_up "$@";;
  load)      shift; cmd_load "${1:-}" "${2:-}";;
  logs)      shift; cmd_logs "${1:-platform}";;
  dump)      shift; cmd_dump "${1:-platform}";;
  status)    cmd_status;;
  sh)        shift; cmd_sh "${1:-platform}";;
  restart)   shift; cmd_restart "${1:-}";;
  mongo-url) shift; cmd_mongo_url "${1:-}";;
  check-url) shift; cmd_check_url "${1:-}";;
  mongo)     cmd_mongo;;
  rewire-mongo) cmd_rewire_mongo;;
  down)      cmd_down;;
  *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac
