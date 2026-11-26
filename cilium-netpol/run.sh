#!/bin/bash
# Kind test for A4i-tech/.github#740: do the existing infra-ops NetworkPolicies behave as intended under Cilium?
# Phase 1 has no policies (today's kube-dev, nothing enforced). Phase 2 applies every NetworkPolicy file from infra-ops
# and runs an allow/deny matrix from probe pods labelled like the real workloads.
# "Public" is a container on 198.51.100.0/24, IMDS is 169.254.169.254 on every node, API server is 10.0.0.1:443 as on AKS.
# Usage: INFRA_OPS=/path/to/infra-ops [KEEP=1] [REUSE=1] ./run.sh | ./run.sh down. Linux amd64 only.
set -euo pipefail

CLUSTER_NAME='cilium-netpol'
KEEP="${KEEP:-0}"
REUSE="${REUSE:-0}"
CILIUM_VERSION="${CILIUM_VERSION:-1.17.6}"
NODE_IMAGE="${NODE_IMAGE:-}"
PUB_NET=cilium-netpol-pub
PUB_IP=198.51.100.10
IMDS=169.254.169.254
API=10.0.0.1

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/kind-${CLUSTER_NAME}"

down() {
  docker rm -f cilium-netpol-pubsrv >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  docker network rm "$PUB_NET" >/dev/null 2>&1 || true
}
if [ "${1:-}" = down ]; then down; echo "removed $CLUSTER_NAME"; exit 0; fi

INFRA_OPS="${INFRA_OPS:?set INFRA_OPS to your infra-ops checkout}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"; [ "$KEEP" = 1 ] || down' EXIT

pass=0 failn=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }

PORTS="22 80 443 3000 4222 5432 6379 6380 8080 8088 8222 27017"
declare -A IP NS

echo '=== [1/5] Cluster with Cilium ==='
if [ "$REUSE" = 1 ] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "reusing $CLUSTER_NAME"
else
  down
  cat > "$WORKDIR/kind.yaml" <<Y
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.0.0.0/16
nodes:
  - role: control-plane
  - role: worker
  - role: worker
Y
  kind create cluster --name "$CLUSTER_NAME" --config "$WORKDIR/kind.yaml" ${NODE_IMAGE:+--image "$NODE_IMAGE"}
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  helm install cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system --wait --timeout 8m \
    --set ipam.mode=kubernetes --set operator.replicas=1 >/dev/null
  kubectl wait --for=condition=ready node --all --timeout=300s
fi

echo '=== [2/5] Mock public host, IMDS, namespaces, probe pods ==='
docker network inspect "$PUB_NET" >/dev/null 2>&1 || docker network create --subnet 198.51.100.0/24 "$PUB_NET" >/dev/null
docker rm -f cilium-netpol-pubsrv >/dev/null 2>&1 || true
srv_cmd=""; for p in $PORTS; do srv_cmd="$srv_cmd httpd -f -p $p &"; done
docker run -d --name cilium-netpol-pubsrv --network "$PUB_NET" --ip "$PUB_IP" busybox:1.36 sh -c "$srv_cmd wait" >/dev/null
for n in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker network connect "$PUB_NET" "$n" 2>/dev/null || true
  docker exec "$n" ip addr add "$IMDS/32" dev lo 2>/dev/null || true
done

NAMESPACES="byoeb shiksha seeds nats docmost umami stakesight pgadmin superset ingress-nginx other imds-mock"
for n in $NAMESPACES; do kubectl create namespace "$n" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
for n in $NAMESPACES; do until kubectl get sa default -n "$n" >/dev/null 2>&1; do sleep 1; done; done
kubectl label ns superset kubernetes.io/metadata.name=superset --overwrite >/dev/null
kubectl delete netpol --all -A >/dev/null 2>&1 || true

cat <<Y | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: imds, namespace: imds-mock}
spec:
  selector: {matchLabels: {app: imds}}
  template:
    metadata: {labels: {app: imds}}
    spec:
      hostNetwork: true
      tolerations: [{operator: Exists}]
      containers:
        - {name: h, image: "busybox:1.36", command: ["httpd", "-f", "-p", "80"]}
Y

mkpod() { # ns name labels
  local ns=$1 name=$2 labels=$3 cmd="" p lab=""
  for p in $PORTS; do cmd="$cmd httpd -f -p $p &"; done
  for l in ${labels//,/ }; do lab="$lab, \"${l%%=*}\": \"${l#*=}\""; done
  cat <<Y | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels: {"probe": "$name"$lab}
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh", "-c", "$cmd wait"]
      readinessProbe: {tcpSocket: {port: 80}, periodSeconds: 5, failureThreshold: 2}
Y
  NS[$name]=$ns
}
# ns name labels
mkpod byoeb byoeb-app app=byoeb-chat
mkpod byoeb byoeb-other app=other
mkpod shiksha shiksha-api app=shiksha-api
mkpod shiksha shiksha-worker app=shiksha-presentation-worker
mkpod shiksha shiksha-misc app=shiksha-fe
mkpod seeds seeds-app app=seeds-api
mkpod nats nats-0 app=nats
mkpod nats nats-backup app=nats-backup
mkpod docmost docmost app=docmost
mkpod docmost docmost-pg app.kubernetes.io/component=postgres
mkpod docmost docmost-redis app.kubernetes.io/component=redis
mkpod docmost docmost-backup app=docmost-backup
mkpod umami umami app=umami
mkpod umami umami-db app=umami-db
mkpod umami umami-backup app=umami-backup
mkpod stakesight stakesight app=stakesight
mkpod stakesight stakesight-pg app.kubernetes.io/component=postgres
mkpod stakesight stakesight-backup app=stakesight-backup
mkpod stakesight stakesight-migrate app=stakesight-migrate
mkpod pgadmin pgadmin app=pgadmin
mkpod superset superset app=superset
mkpod superset analytics-db app=analytics-db
mkpod superset analytics-etl app=analytics-etl
mkpod superset analytics-db-backup app=analytics-db-backup
mkpod ingress-nginx ingress app=ingress-nginx
mkpod other outsider app=outsider
for n in $NAMESPACES; do kubectl -n "$n" wait --for=condition=ready pod --all --timeout=300s >/dev/null; done
kubectl -n imds-mock rollout status ds/imds --timeout=120s >/dev/null
for p in "${!NS[@]}"; do IP[$p]=$(kubectl get pod "$p" -n "${NS[$p]}" -o jsonpath='{.status.podIP}'); done

# can SRC DST PORT: succeeds when a TCP connection to DST:PORT works. DST is a probe pod name or a literal IP.
can() {
  local src=$1 dst=$2 port=$3 addr=$2
  [ -n "${IP[$dst]:-}" ] && addr=${IP[$dst]}
  kubectl exec -n "${NS[$src]}" "$src" -- sh -c "echo | nc -w 4 $addr $port" >/dev/null 2>&1
}
A() { if can "$@"; then ok "$1 -> $2:$3 allowed"; else bad "$1 -> $2:$3 should be allowed"; fi; }
D() { if can "$@"; then bad "$1 -> $2:$3 should be blocked"; else ok "$1 -> $2:$3 blocked"; fi; }
dns() { if kubectl exec -n "${NS[$1]}" "$1" -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then ok "$1 resolves DNS"; else bad "$1 cannot resolve DNS"; fi; }

echo '=== [3/5] Baseline, no policies (today on kube-dev) ==='
A byoeb-app "$PUB_IP" 80
A byoeb-app "$PUB_IP" 22
A byoeb-app "$IMDS" 80
A byoeb-app "$API" 443
A shiksha-misc nats-0 8222
A outsider docmost-pg 5432

echo '=== [4/5] Apply every infra-ops NetworkPolicy ==='
cd "$INFRA_OPS"
for p in byoeb shiksha seeds; do
  sed "s/PARTNER_NAMESPACE/$p/" partners/_base/network-policy.yaml | kubectl apply -n "$p" -f - >/dev/null
  kubectl apply -n "$p" -f "partners/$p/apps/network-policy.yaml" >/dev/null
done
for a in docmost nats umami stakesight; do kubectl apply -n "$a" -f "apps/$a/network-policy.yaml" >/dev/null; done
kubectl apply -f apps/pgadmin/network-policy.yaml >/dev/null
kubectl apply -f partners/shiksha/superset/network-policy.yaml >/dev/null
echo "policies applied: $(kubectl get netpol -A --no-headers | wc -l)"
sleep 30

echo '=== [5/5] Enforcement matrix ==='
for p in byoeb-app shiksha-misc seeds-app nats-0 docmost umami stakesight pgadmin superset; do dns "$p"; done

echo '--- kubelet probes still pass under default-deny'
notready=$(kubectl get pods -A --no-headers | awk '$1!="kube-system" && $1!="local-path-storage" && $3!="1/1" {print $1"/"$2}' | tr '\n' ' ')
if [ -z "$notready" ]; then ok "all probe pods still Ready"; else bad "pods NotReady: $notready"; fi

echo '--- ingress-nginx and outsiders'
A ingress byoeb-app 8080
A ingress docmost 3000
A ingress umami 3000
A ingress stakesight 8080
A ingress superset 8088
A ingress pgadmin 80
A ingress shiksha-misc 80
D ingress superset 80
D ingress docmost-pg 5432
D ingress nats-0 8222
D outsider byoeb-app 8080
D outsider docmost 3000
D outsider superset 8088
D outsider docmost-pg 5432
D outsider umami-db 5432
D outsider analytics-db 5432

echo '--- intra-namespace and app-to-db'
A byoeb-other byoeb-app 8080
A docmost docmost-pg 5432
A docmost docmost-redis 6379
A docmost-backup docmost-pg 5432
D docmost-backup docmost-redis 6379
A umami umami-db 5432
A umami-backup umami-db 5432
A stakesight stakesight-pg 5432
A stakesight-migrate stakesight-pg 5432
A stakesight-backup stakesight-pg 5432
A superset analytics-db 5432
D superset umami-db 5432
D stakesight umami-db 5432

echo '--- cross-namespace'
D byoeb-app shiksha-misc 80
D byoeb-app docmost 3000
D byoeb-app nats-0 4222
A shiksha-api nats-0 4222
A shiksha-worker nats-0 4222
D shiksha-api nats-0 8222
D shiksha-misc nats-0 4222
D outsider nats-0 4222
A nats-backup nats-0 4222
D nats-backup nats-0 8222
A analytics-etl umami-db 5432
A pgadmin analytics-db 5432
D pgadmin analytics-db 80
D analytics-etl docmost-pg 5432
D analytics-etl byoeb-app 8080

echo '--- internet egress'
A byoeb-app "$PUB_IP" 443
A byoeb-app "$PUB_IP" 27017
D byoeb-app "$PUB_IP" 80
D byoeb-app "$PUB_IP" 22
A shiksha-misc "$PUB_IP" 443
D shiksha-misc "$PUB_IP" 27017
A seeds-app "$PUB_IP" 6380
A seeds-app "$PUB_IP" 443
D seeds-app "$PUB_IP" 27017
A stakesight "$PUB_IP" 443
A stakesight-backup "$PUB_IP" 443
D stakesight-migrate "$PUB_IP" 443
D umami "$PUB_IP" 443
A umami-backup "$PUB_IP" 443
D docmost "$PUB_IP" 443
A docmost-backup "$PUB_IP" 443
D docmost-pg "$PUB_IP" 443
D nats-0 "$PUB_IP" 443
A nats-backup "$PUB_IP" 443
D superset "$PUB_IP" 443
A analytics-etl "$PUB_IP" 443
A analytics-etl "$PUB_IP" 27017
D analytics-etl "$PUB_IP" 80
A analytics-db-backup "$PUB_IP" 443
D pgadmin "$PUB_IP" 443

echo '--- IMDS and API server'
for p in byoeb-app shiksha-misc seeds-app docmost stakesight umami nats-0 pgadmin superset analytics-etl; do D "$p" "$IMDS" 80; done
for p in byoeb-app shiksha-misc analytics-etl stakesight; do D "$p" "$API" 443; done

echo
echo "passed: $pass  failed: $failn"
[ "$failn" -eq 0 ]
