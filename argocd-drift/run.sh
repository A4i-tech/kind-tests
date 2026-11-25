#!/bin/bash
# Reproduces the permanent OutOfSync drift on kube-dev (ESO CRD defaults, StatefulSet volumeClaimTemplates defaults)
# and the extra sync every new git revision causes, which fires the ArgoCD Notifications. Same ArgoCD (2.14.x,
# chart 7.9.1) and ESO CRDs (v0.10.3) as kube-dev. Validates the ignoreDifferences set added to the a4i templates.
# Keeps the cluster by default, rerun with REUSE=1 to skip the install. `./<script> down` deletes it, KEEP=0 deletes it on exit.
# Linux amd64 only.
set -euo pipefail

CLUSTER_NAME='argocd-drift'
NODE_IMAGE="${NODE_IMAGE:-}"
KEEP="${KEEP:-1}"
ESO_CRDS='https://raw.githubusercontent.com/external-secrets/external-secrets/v0.10.3/deploy/crds/bundle.yaml'

[ "${1:-}" = down ] && { kind delete cluster --name "$CLUSTER_NAME"; rm -f "$HOME/.kube/kind-${CLUSTER_NAME}"; exit 0; }

BIN=$HOME/.local/bin
export PATH="$BIN:$PATH"
export KUBECONFIG="$HOME/.kube/kind-${CLUSTER_NAME}"
WORKDIR=$(mktemp -d)
GITPORT=9431
trap 'pkill -f "git daemon.*${WORKDIR}" 2>/dev/null || true; rm -rf "$WORKDIR"; [ "$KEEP" = 1 ] || { kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true; rm -f "$KUBECONFIG"; }' EXIT

pass=0 failn=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }
sync_of() { kubectl get application "$1" -n argocd -o jsonpath='{.status.sync.status}'; }
rev_of()  { kubectl get application "$1" -n argocd -o jsonpath='{.status.operationState.syncResult.revision}'; }

echo '=== [1/6] Cluster and ArgoCD ==='
if [ "${REUSE:-0}" = 1 ] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind export kubeconfig --name "$CLUSTER_NAME"
  kubectl delete application baseline fixed -n argocd --ignore-not-found >/dev/null
  kubectl delete namespace drift-base drift-fix --ignore-not-found --wait=true >/dev/null
else
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER_NAME" ${NODE_IMAGE:+--image "$NODE_IMAGE"} --wait 180s
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace argocd >/dev/null
helm upgrade --install argocd argo/argo-cd --version 7.9.1 -n argocd \
  --set dex.enabled=false --set notifications.enabled=false --set applicationSet.enabled=false \
  --set server.replicas=0 --wait --timeout 600s >/dev/null
curl -sSL "$ESO_CRDS" | kubectl apply --server-side -f - >/dev/null
kubectl wait --for=condition=established crd/externalsecrets.external-secrets.io --timeout=60s >/dev/null
fi
kubectl apply -f - >/dev/null <<Y
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  sourceRepos: ['*']
  destinations: [{namespace: '*', server: '*'}]
  clusterResourceWhitelist: [{group: '*', kind: '*'}]
Y

echo '=== [2/6] Fixture repo ==='
R="$WORKDIR/fixture-repo"
mkdir -p "$R/app"
git -C "$R" init -q -b main
cat > "$R/app/externalsecret.yaml" <<'Y'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: fixture-es
  namespace: drift-test
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-key-vault
    kind: ClusterSecretStore
  target:
    name: fixture-es
  data:
    - secretKey: k
      remoteRef:
        key: some-secret
        property: k
Y
cat > "$R/app/statefulset.yaml" <<'Y'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: fixture-sts
  namespace: drift-test
spec:
  serviceName: fixture-sts
  replicas: 0
  selector:
    matchLabels: {app: fixture-sts}
  template:
    metadata:
      labels: {app: fixture-sts}
    spec:
      containers:
        - name: c
          image: busybox:1.36
          command: ["sleep", "3600"]
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
Y
echo "a" > "$R/unrelated.txt"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m init
git daemon --reuseaddr --base-path="$WORKDIR" --export-all --listen=0.0.0.0 --port=$GITPORT &
sleep 1
GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -v : | head -1)
REPO="git://$GW:$GITPORT/fixture-repo"

echo '=== [3/6] Applications: today (baseline) and with the fix ==='
app() {
cat <<Y
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $REPO
    targetRevision: main
    path: app
  destination:
    server: https://kubernetes.default.svc
    namespace: drift-test
$2
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true, PruneLast=true]
Y
}
BASE='  ignoreDifferences:
    - {group: apps, kind: StatefulSet, jsonPointers: ["/spec/updateStrategy/rollingUpdate/partition"]}
    - {group: external-secrets.io, kind: ExternalSecret, jsonPointers: ["/status"]}'
FIX="$BASE
    - group: external-secrets.io
      kind: ExternalSecret
      jqPathExpressions:
        - .spec.data[]?.remoteRef.conversionStrategy
        - .spec.data[]?.remoteRef.decodingStrategy
        - .spec.data[]?.remoteRef.metadataPolicy
        - .spec.dataFrom[]?.extract.conversionStrategy
        - .spec.dataFrom[]?.extract.decodingStrategy
        - .spec.dataFrom[]?.extract.metadataPolicy
        - .spec.target.creationPolicy
        - .spec.target.deletionPolicy
        - .spec.target.template.engineVersion
        - .spec.target.template.mergePolicy
    - group: apps
      kind: StatefulSet
      jqPathExpressions:
        - .spec.volumeClaimTemplates[]?.apiVersion
        - .spec.volumeClaimTemplates[]?.kind
        - .spec.volumeClaimTemplates[]?.status
        - .spec.volumeClaimTemplates[]?.spec.volumeMode"
# fixed app uses a separate namespace so both can coexist
{ app baseline "$BASE" | sed 's/namespace: drift-test/namespace: drift-base/'; echo '---'; app fixed "$FIX" | sed 's/namespace: drift-test/namespace: drift-fix/'; } > "$WORKDIR/apps.yaml"
# manifests hardcode the namespace, so render one copy per app path
mkdir -p "$R/base" "$R/fix"
for f in externalsecret statefulset; do
  sed 's/drift-test/drift-base/' "$R/app/$f.yaml" > "$R/base/$f.yaml"
  sed 's/drift-test/drift-fix/' "$R/app/$f.yaml" > "$R/fix/$f.yaml"
done
rm -rf "$R/app"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m split
sed -i '0,/path: app/s#path: app#path: base#; 0,/path: app/s#path: app#path: fix#' "$WORKDIR/apps.yaml"
kubectl apply -f "$WORKDIR/apps.yaml" >/dev/null

echo '=== [4/6] Initial sync and drift ==='
for i in $(seq 1 60); do
  [ "$(kubectl get application baseline -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null)" = Succeeded ] &&
  [ "$(kubectl get application fixed -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null)" = Succeeded ] && break
  sleep 5
done
sleep 30
echo "baseline: $(sync_of baseline)  fixed: $(sync_of fixed)"
kubectl get application baseline -n argocd -o json | python3 -c '
import json,sys
a=json.load(sys.stdin)
print("baseline OutOfSync resources:",[r["kind"]+"/"+r["name"] for r in a["status"].get("resources",[]) if r.get("status")=="OutOfSync"])'
[ "$(sync_of baseline)" = OutOfSync ] && ok "baseline is OutOfSync (reproduces kube-dev)" || bad "baseline did not reproduce the drift"
[ "$(sync_of fixed)" = Synced ] && ok "fixed is Synced" || bad "fixed is not Synced"

echo '=== [5/6] Unrelated commit: does each app sync again? ==='
b0=$(rev_of baseline); f0=$(rev_of fixed)
echo b > "$R/unrelated.txt"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "unrelated change"
new=$(git -C "$R" rev-parse HEAD)
kubectl annotate application baseline fixed -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for i in $(seq 1 40); do [ "$(rev_of baseline)" = "$new" ] && break; sleep 3; done
sleep 15
b1=$(rev_of baseline); f1=$(rev_of fixed)
[ "$b1" != "$b0" ] && ok "baseline synced again on an unrelated commit (this is what fires the notification)" || bad "baseline did not resync"
[ "$f1" = "$f0" ] && ok "fixed did not sync on an unrelated commit (no notification)" || bad "fixed resynced on an unrelated commit"

echo '=== [6/6] Real change still syncs on the fixed app ==='
sed -i 's/replicas: 0/replicas: 1/' "$R/fix/statefulset.yaml"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "real change"
new2=$(git -C "$R" rev-parse HEAD)
kubectl annotate application fixed -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for i in $(seq 1 40); do [ "$(rev_of fixed)" = "$new2" ] && break; sleep 3; done
[ "$(rev_of fixed)" = "$new2" ] && ok "fixed app syncs a real change" || bad "fixed app missed a real change"
[ "$(kubectl get sts fixture-sts -n drift-fix -o jsonpath='{.spec.replicas}')" = 1 ] && ok "real change applied to the cluster" || bad "real change not applied"

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
