#!/bin/bash
# Kind test: deploys apps/umami + shiksha-fe, wires umami tracking into shiksha-fe, smoke tests both.
# Targets apps/umami/ (A4i-tech/infra-ops#44) — platform/umami/ (PR #36) is superseded, gone from a4i/main.
# fe-deployment.yaml serves index.html baked into the image; an initContainer here copies it to an
# emptyDir and injects the umami script tag, since nothing in the real manifest does this for us.
# Patches the rendered manifest before first apply, not apply-then-patch (that wedged kubelet once).
# Linux amd64 only.
set -euo pipefail

CLUSTER_NAME='umami-shiksha-sandbox'
INFRA_DIR="${INFRA_DIR:?set INFRA_DIR to your infra-ops checkout (must have apps/umami/)}"
UMAMI_PORT=3000
SHIKSHA_FE_PORT=8081

BIN=$HOME/.local/bin
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# Isolated kubeconfig, never touches the default ~/.kube/config.
export KUBECONFIG="$HOME/.kube/kind-${CLUSTER_NAME}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT  # port-forwards below are meant to outlive this script

pkill -f "port-forward -n umami svc/umami" 2>/dev/null || true
pkill -f "port-forward -n shiksha svc/shiksha-fe-svc" 2>/dev/null || true

echo '=== [1/6] Checking dependencies ==='
command -v kubectl &>/dev/null || { curl -sSLo "$BIN/kubectl" "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"; chmod +x "$BIN/kubectl"; }
command -v kind &>/dev/null || { curl -sSLo "$BIN/kind" https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64; chmod +x "$BIN/kind"; }
python3 -c 'import yaml' 2>/dev/null || { echo 'missing: python3 PyYAML (pip install pyyaml)' >&2; exit 1; }

echo "=== [2/6] Creating kind cluster: $CLUSTER_NAME ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo 'Cluster already exists, skipping.'
  kind export kubeconfig --name "$CLUSTER_NAME"
else
  kind create cluster --name "$CLUSTER_NAME"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=ready node --all --timeout=120s

echo '=== [3/6] Deploying umami (namespace + secret + kustomize) ==='
kubectl create namespace umami --dry-run=client -o yaml | kubectl apply -f -
# restic-password/azure-account-* are dummy, this test doesn't exercise backup/restore.
kubectl create secret generic umami-app-secrets -n umami \
  --from-literal=db-password='umamiLocalTest123' \
  --from-literal=app-secret="$(openssl rand -hex 32)" \
  --from-literal=restic-password='unused-in-kind' \
  --from-literal=azure-account-name='unused-in-kind' \
  --from-literal=azure-account-key='unused-in-kind' \
  --dry-run=client -o yaml | kubectl apply -f -

cd "$INFRA_DIR"
# ExternalSecret's CRD isn't in kind (no ESO here); managed-csi-premium isn't a real
# storage class in kind either, drop it so the PVC binds against kind's own default.
kubectl kustomize apps/umami/ | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") not in ("ExternalSecret", "Certificate", "Ingress")]
for d in docs:
    if d.get("kind") == "StatefulSet":
        for vct in d["spec"].get("volumeClaimTemplates", []):
            vct["spec"].pop("storageClassName", None)
yaml.safe_dump_all(docs, sys.stdout)
' | kubectl apply -f -
kubectl wait --for=condition=ready pod -l app=umami-db -n umami --timeout=120s
kubectl wait --for=condition=available deployment/umami -n umami --timeout=120s
echo 'umami ready'

echo '=== [4/6] Registering umami test website ==='
kubectl port-forward -n umami svc/umami "${UMAMI_PORT}:3000" >"$WORKDIR/umami-pf.log" 2>&1 &
sleep 3

TOKEN=$(curl -s -X POST "http://localhost:${UMAMI_PORT}/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"umami"}' | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")

WEBSITE_ID=$(curl -s -X POST "http://localhost:${UMAMI_PORT}/api/websites" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"shiksha-local-test","domain":"localhost"}' | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "umami website id: $WEBSITE_ID"

echo '=== [5/6] Deploying shiksha-fe (patched for current image; be/api best-effort) ==='
kubectl kustomize partners/shiksha > "$WORKDIR/shiksha-rendered.yaml"

UMAMI_PORT="$UMAMI_PORT" WEBSITE_ID="$WEBSITE_ID" WORKDIR="$WORKDIR" python3 - <<'PYEOF'
import os, yaml

umami_port = os.environ['UMAMI_PORT']
website_id = os.environ['WEBSITE_ID']
workdir = os.environ['WORKDIR']

with open(f'{workdir}/shiksha-rendered.yaml') as f:
    docs = list(yaml.safe_load_all(f))

skip_kinds = {'Certificate', 'Ingress', 'ExternalSecret'}
docs = [d for d in docs if d and d.get('kind') not in skip_kinds]

# index.html is baked into the image, no file in the repo to inject the script tag into.
# initContainer copies /srv out, patches it, main container mounts the copy back over /srv.
init_script = (
    "cp -r /srv/. /patched/\n"
    "sed -i 's|<script src=\"assets/env.js\"></script>|"
    f'<script src="assets/env.js"></script><script defer src="http://localhost:{umami_port}/script.js" '
    f'data-website-id="{website_id}"></script>|\' /patched/index.html\n'
)

for d in docs:
    if d.get('kind') == 'Deployment' and d['metadata']['name'] == 'shiksha-fe':
        pod_spec = d['spec']['template']['spec']
        fe_container = next(c for c in pod_spec['containers'] if c['name'] == 'shiksha-fe')
        pod_spec['volumes'].append({'name': 'patched-srv', 'emptyDir': {}})
        pod_spec['initContainers'] = [{
            'name': 'patch-umami-script-tag',
            'image': fe_container['image'],
            'command': ['sh', '-ec', init_script],
            'volumeMounts': [{'name': 'patched-srv', 'mountPath': '/patched'}],
        }]
        # patched-srv (whole /srv) must precede fe-env's subPath mount so that mount
        # lands on top of it, not hidden underneath.
        env_mount = next(vm for vm in fe_container['volumeMounts'] if vm['name'] == 'fe-env')
        other_mounts = [vm for vm in fe_container['volumeMounts'] if vm['name'] != 'fe-env']
        fe_container['volumeMounts'] = other_mounts + [
            {'name': 'patched-srv', 'mountPath': '/srv'},
            env_mount,
        ]

with open(f'{workdir}/shiksha-filtered.yaml', 'w') as f:
    yaml.safe_dump_all(docs, f)
PYEOF

kubectl apply -f "$WORKDIR/shiksha-filtered.yaml"

kubectl create secret generic shiksha-be-secret -n shiksha --from-literal=PLACEHOLDER=dummy --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic shiksha-api-secret -n shiksha --from-literal=PLACEHOLDER=dummy --dry-run=client -o yaml | kubectl apply -f -

kubectl wait --for=condition=available deployment/shiksha-fe -n shiksha --timeout=180s
echo 'shiksha-fe ready'

echo '=== [6/6] Done ==='
kubectl port-forward -n shiksha svc/shiksha-fe-svc "${SHIKSHA_FE_PORT}:80" >"$WORKDIR/shiksha-fe-pf.log" 2>&1 &
sleep 2
echo '============================================'
echo " umami:       http://localhost:${UMAMI_PORT}   admin / umami"
echo " shiksha-fe:  http://localhost:${SHIKSHA_FE_PORT}"
echo " website id:  ${WEBSITE_ID}"
echo '============================================'
echo ' Open shiksha-fe in a browser, click around, then check umami dashboard'
echo ' for the pageview/session. be/api pods are NOT functional (dummy secrets) —'
echo ' only frontend static traffic is being tracked here.'
echo " Teardown: kind delete cluster --name ${CLUSTER_NAME} && rm -f ${KUBECONFIG}"
echo '============================================'
