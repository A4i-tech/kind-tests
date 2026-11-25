#!/bin/bash
# Kind test for apps/qdrant (A4i-tech/.github#852): PSS restricted admission, API key, NetworkPolicy enforcement
# (Calico), backup to a restic rest-server, wipe + automatic restore, restore no-op on a populated Qdrant.
# ExternalSecret and storageClassName are dropped, restic repo is repointed at an in-cluster rest-server.
# Linux amd64 only.
set -euo pipefail

CLUSTER_NAME='qdrant-sandbox'
INFRA_DIR="${INFRA_DIR:?set INFRA_DIR to your infra-ops checkout (must have apps/qdrant/)}"
KEEP="${KEEP:-0}"
NODE_IMAGE="${NODE_IMAGE:-}"
CALICO_URL='https://raw.githubusercontent.com/projectcalico/calico/v3.30.3/manifests/calico.yaml'

BIN=$HOME/.local/bin
export PATH="$BIN:$PATH"
export KUBECONFIG="$HOME/.kube/kind-${CLUSTER_NAME}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"; [ "$KEEP" = 1 ] || kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true' EXIT

pass=0 failn=0
ok()   { echo "ok:   $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $*"; failn=$((failn + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
checkno() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

KEY=$(openssl rand -hex 16)
URL=http://qdrant.qdrant.svc:6333

echo '=== [1/7] Cluster with Calico ==='
cat > "$WORKDIR/kind.yaml" <<Y
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
Y
curl -sSLo "$WORKDIR/calico.yaml" "$CALICO_URL"
setup_cluster() {
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kind create cluster --name "$CLUSTER_NAME" --config "$WORKDIR/kind.yaml" ${NODE_IMAGE:+--image "$NODE_IMAGE"} &&
    kubectl apply -f "$WORKDIR/calico.yaml" >/dev/null &&
    kubectl -n kube-system rollout status ds/calico-node --timeout=300s &&
    kubectl wait --for=condition=ready node --all --timeout=300s
}
for attempt in 1 2 3; do
  setup_cluster && break
  echo "cluster setup attempt $attempt hung or failed, retrying"
  [ "$attempt" -lt 3 ] || { echo "FATAL: cluster setup failed 3 times" >&2; exit 1; }
done

echo '=== [2/7] Render and mock apps/qdrant ==='
for n in byoeb shiksha other restic-test; do kubectl create namespace "$n" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
for n in byoeb shiksha other restic-test; do until kubectl get sa default -n "$n" >/dev/null 2>&1; do sleep 1; done; done
kubectl run restic-rest -n restic-test --image=restic/rest-server:0.13.0 --env=OPTIONS="--no-auth" --port=8000 >/dev/null
kubectl expose pod restic-rest -n restic-test --port=8000 >/dev/null
kubectl wait --for=condition=ready pod/restic-rest -n restic-test --timeout=120s

cd "$INFRA_DIR"
kubectl kustomize apps/qdrant > "$WORKDIR/raw.yaml"
python3 - "$WORKDIR" <<'PY'
import sys, yaml
w = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(f"{w}/raw.yaml")) if d and d["kind"] != "ExternalSecret"]
def pods(d):
    spec = d["spec"].get("jobTemplate", {}).get("spec", d["spec"])
    return spec["template"]["spec"]
for d in docs:
    if d["kind"] == "StatefulSet":
        for v in d["spec"]["volumeClaimTemplates"]:
            v["spec"].pop("storageClassName", None)
    if d["kind"] in ("CronJob", "Job"):
        p = pods(d)
        for c in p.get("initContainers", []) + p["containers"]:
            for e in c.get("env", []):
                if e["name"] == "RESTIC_REPOSITORY":
                    e["value"] = "rest:http://restic-rest.restic-test.svc:8000/qd"
docs.append({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
  "metadata": {"name": "kind-test-allow-rest", "namespace": "qdrant"},
  "spec": {"podSelector": {"matchLabels": {"app": "qdrant-backup"}}, "policyTypes": ["Egress"],
    "egress": [{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "restic-test"}}}],
                "ports": [{"port": 8000, "protocol": "TCP"}]}]}})
job = [d for d in docs if d["kind"] == "Job"]
rest = [d for d in docs if d["kind"] != "Job"]
yaml.safe_dump_all(rest, open(f"{w}/base.yaml", "w"))
yaml.safe_dump_all(job, open(f"{w}/job.yaml", "w"))
PY

echo '=== [3/7] Deploy (PSS restricted is enforced on the namespace) ==='
kubectl apply -f - <<Y >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: qdrant
Y
kubectl create secret generic qdrant-app-secrets -n qdrant \
  --from-literal=api-key="$KEY" --from-literal=restic-password=kindtest \
  --from-literal=azure-account-name=unused --from-literal=azure-account-key=unused >/dev/null
kubectl apply -f "$WORKDIR/base.yaml" 2>&1 | grep -i -E "warning|forbidden|error" && bad "apply produced warnings or errors" || ok "apply clean, no PSS warnings"
kubectl rollout status sts/qdrant -n qdrant --timeout=300s
kubectl apply -f "$WORKDIR/job.yaml" >/dev/null
kubectl wait --for=condition=complete job/qdrant-restore-check -n qdrant --timeout=300s && ok "fresh install restore job completes as no-op" || bad "fresh install restore job"
kubectl logs job/qdrant-restore-check -n qdrant -c fetch | grep -q "nothing to restore" && ok "restore job took fresh-install path" || bad "restore job fresh path log"

echo '=== [4/7] Hardening checks ==='
Q="kubectl exec -n qdrant qdrant-0 --"
[ "$($Q id -u)" = 1000 ] && ok "runs as uid 1000" || bad "uid"
checkno "root filesystem is read-only" $Q sh -c 'touch /probe'
check "storage volume is writable" $Q sh -c 'touch /qdrant/storage/probe && rm /qdrant/storage/probe'
[ "$(kubectl get pod qdrant-0 -n qdrant -o jsonpath='{.spec.automountServiceAccountToken}')" = false ] && ok "no service account token" || bad "token automount"
check "ResourceQuota present" kubectl get resourcequota qdrant -n qdrant
kubectl run pssprobe -n qdrant --image=busybox --restart=Never --dry-run=server -o name >/dev/null 2>&1 && bad "PSS admitted a privileged-default pod" || ok "PSS rejects non-compliant pod"

echo '=== [5/7] Access and NetworkPolicy ==='
kubectl run c-byoeb -n byoeb --image=curlimages/curl:8.23.0 --command -- sleep 3600 >/dev/null
kubectl run c-other -n other --image=curlimages/curl:8.23.0 --command -- sleep 3600 >/dev/null
kubectl wait --for=condition=ready pod/c-byoeb -n byoeb --timeout=180s >/dev/null
kubectl wait --for=condition=ready pod/c-other -n other --timeout=180s >/dev/null
code() { kubectl exec -n "$1" "$2" -- curl -s -m 6 -o /dev/null -w '%{http_code}' "${@:3}" 2>/dev/null || true; }
[ "$(code byoeb c-byoeb $URL/collections)" = 401 ] && ok "byoeb ns reaches qdrant, no key gives 401" || bad "byoeb no key"
[ "$(code byoeb c-byoeb -H "api-key: $KEY" $URL/collections)" = 200 ] && ok "byoeb ns with key gives 200" || bad "byoeb with key"
[ "$(code other c-other -H "api-key: $KEY" $URL/collections)" != 200 ] && ok "other ns blocked by NetworkPolicy" || bad "other ns reached qdrant"
[ "$(code byoeb c-byoeb $URL/readyz)" = 200 ] && ok "/readyz needs no key" || bad "readyz"

echo '=== [6/7] Data, backup, wipe, restore ==='
H=(-H "api-key: $KEY" -H 'content-type: application/json')
K() { kubectl exec -i -n byoeb c-byoeb -- curl -s -m 60 "${H[@]}" "$@"; }
K -X PUT $URL/collections/t768 -d '{"vectors":{"size":768,"distance":"Cosine"}}' | grep -q '"result":true' && ok "collection created" || bad "create collection"
python3 -c '
import json, random
random.seed(1)
print(json.dumps({"points":[{"id":i,"vector":[random.random() for _ in range(768)],"payload":{"n":i}} for i in range(100)]}))' > "$WORKDIR/pts.json"
kubectl exec -i -n byoeb c-byoeb -- curl -s -m 60 -X PUT "${H[@]}" "$URL/collections/t768/points?wait=true" --data-binary @- < "$WORKDIR/pts.json" | grep -q '"status":"completed"' && ok "100 points upserted" || bad "upsert"
count() { K -X POST $URL/collections/t768/points/count -d '{"exact":true}' | grep -o '"count":[0-9]*' | cut -d: -f2; }
[ "$(count)" = 100 ] && ok "count is 100" || bad "count before"

kubectl create job --from=cronjob/qdrant-backup bk1 -n qdrant >/dev/null
kubectl wait --for=condition=complete job/bk1 -n qdrant --timeout=300s && ok "backup job completes" || { kubectl logs job/bk1 -n qdrant --all-containers | tail -20; bad "backup job"; }
kubectl logs job/bk1 -n qdrant -c push | tail -3
kubectl run rs -n restic-test --rm -i --restart=Never --image=restic/restic:0.20.0 --env=RESTIC_PASSWORD=kindtest --env=RESTIC_REPOSITORY=rest:http://restic-rest:8000/qd -- snapshots 2>/dev/null | grep -c "1 snapshots" | grep -q 1 && ok "restic repo holds the snapshot" || bad "restic snapshot count"

echo "wiping: delete sts, pvc, restore job"
kubectl delete sts qdrant -n qdrant --wait=true >/dev/null
kubectl delete pvc data-qdrant-0 -n qdrant --wait=true >/dev/null
kubectl delete job qdrant-restore-check -n qdrant >/dev/null
kubectl apply -f "$WORKDIR/base.yaml" >/dev/null
kubectl rollout status sts/qdrant -n qdrant --timeout=300s
[ "$(K $URL/collections | grep -c '"name":"t768"')" = 0 ] && ok "data is gone after wipe" || bad "wipe did not clear data"
kubectl apply -f "$WORKDIR/job.yaml" >/dev/null
kubectl wait --for=condition=complete job/qdrant-restore-check -n qdrant --timeout=600s && ok "restore job completes" || { kubectl logs job/qdrant-restore-check -n qdrant --all-containers | tail -20; bad "restore job"; }
[ "$(count)" = 100 ] && ok "100 points back after restore" || bad "count after restore"
K -X POST $URL/collections/t768/points/query -d "{\"query\":$(python3 -c 'import json;print(json.dumps([0.5]*768))'),\"limit\":3}" | grep -q '"status":"ok"' && ok "search works after restore" || bad "search after restore"

echo '=== [7/7] Restore is a no-op on a populated Qdrant ==='
kubectl delete job qdrant-restore-check -n qdrant >/dev/null
kubectl apply -f "$WORKDIR/job.yaml" >/dev/null
kubectl wait --for=condition=complete job/qdrant-restore-check -n qdrant --timeout=300s && ok "rerun completes" || bad "rerun"
kubectl logs job/qdrant-restore-check -n qdrant -c check | grep -q "leaving it alone" && ok "rerun left data alone" || bad "rerun log"
[ "$(count)" = 100 ] && ok "count still 100" || bad "count after rerun"

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
