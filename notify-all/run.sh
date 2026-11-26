#!/bin/bash
# Kind test for infra-ops "notify every app" (A4i-tech/.github#777): the cm subscription selector a4i.in/notify!=false,
# and the partners ApplicationSet label default (true unless partner.yaml sets notify: false).
# Mock Teams webhook; email is asserted by the controller's send attempt (mock SMTP has no TLS). Keeps the cluster, REUSE=1 reruns on it, `down` deletes it. Linux amd64 only.
set -euo pipefail

CLUSTER_NAME='notify-all'
CHART_VERSION='7.9.1'
KEEP="${KEEP:-1}"
GITPORT=9432
export KUBECONFIG="$HOME/.kube/kind-${CLUSTER_NAME}"
export PATH="$HOME/.local/bin:$PATH"
[ "${1:-}" = down ] && { kind delete cluster --name "$CLUSTER_NAME"; rm -f "$KUBECONFIG"; exit 0; }
INFRA_OPS="${INFRA_OPS:?set INFRA_OPS to your infra-ops checkout}"

WORKDIR=$(mktemp -d)
trap 'pkill -f "git daemon.*${WORKDIR}" 2>/dev/null || true; rm -rf "$WORKDIR"; [ "$KEEP" = 1 ] || { kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true; rm -f "$KUBECONFIG"; }' EXIT

pass=0 failn=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; failn=$((failn + 1)); }

echo '=== [1/5] Cluster, ArgoCD, mocks ==='
if [ "${REUSE:-0}" = 1 ] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind export kubeconfig --name "$CLUSTER_NAME"
  kubectl delete application,applicationset --all -n argocd --ignore-not-found >/dev/null
  kubectl delete namespace nn-ok nn-unlabeled nn-optout --ignore-not-found --wait=true >/dev/null
  kubectl rollout restart deploy/webhook-mock deploy/mailpit -n argocd >/dev/null
else
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  kind create cluster --name "$CLUSTER_NAME" --wait 180s
  kubectl create namespace argocd >/dev/null
  kubectl apply -n argocd -f - >/dev/null <<'Y'
apiVersion: apps/v1
kind: Deployment
metadata: {name: webhook-mock}
spec:
  replicas: 1
  selector: {matchLabels: {app: webhook-mock}}
  template:
    metadata: {labels: {app: webhook-mock}}
    spec:
      containers:
        - name: m
          image: python:3.12-alpine
          command: ["python","-u","-c"]
          args:
            - |
              import http.server
              class H(http.server.BaseHTTPRequestHandler):
                  def do_POST(s):
                      b=s.rfile.read(int(s.headers.get('content-length',0))).decode()
                      print("WEBHOOK",b.replace("\n"," "),flush=True)
                      s.send_response(200); s.end_headers()
              http.server.HTTPServer(("",80),H).serve_forever()
---
apiVersion: v1
kind: Service
metadata: {name: webhook-mock}
spec: {selector: {app: webhook-mock}, ports: [{port: 80}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: mailpit}
spec:
  replicas: 1
  selector: {matchLabels: {app: mailpit}}
  template:
    metadata: {labels: {app: mailpit}}
    spec:
      containers:
        - name: m
          image: axllent/mailpit:v1.21
          env:
            - {name: MP_SMTP_BIND_ADDR, value: "0.0.0.0:587"}
            - {name: MP_SMTP_AUTH_ACCEPT_ANY, value: "1"}
            - {name: MP_SMTP_AUTH_ALLOW_INSECURE, value: "1"}
---
apiVersion: v1
kind: Service
metadata: {name: mailpit}
spec: {selector: {app: mailpit}, ports: [{name: smtp, port: 587}, {name: api, port: 8025}]}
Y
  kubectl apply -f "$INFRA_OPS/platform/argocd-notifications/notifications-cm.yaml" >/dev/null
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd --version "$CHART_VERSION" -n argocd \
    --set notifications.cm.create=false --set notifications.secret.create=false \
    --set dex.enabled=false --set redis-ha.enabled=false --set server.replicas=0 \
    --set-string 'configs.params.controller\.diff\.server\.side=true' --wait --timeout 10m >/dev/null
  kubectl rollout status deploy/webhook-mock deploy/mailpit -n argocd --timeout=5m >/dev/null
fi
kubectl create secret generic argocd-notifications-secret -n argocd \
  --from-literal=teams_webhook_url=http://webhook-mock.argocd.svc/hook \
  --from-literal=smtp_host=mailpit.argocd.svc --from-literal=smtp_username=argocd@test.local \
  --from-literal=smtp_password=x --from-literal=smtp_from=argocd@test.local \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$INFRA_OPS/platform/argocd-notifications/notifications-cm.yaml" >/dev/null
kubectl apply -f - >/dev/null <<'Y'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: default, namespace: argocd}
spec:
  sourceRepos: ['*']
  destinations: [{namespace: '*', server: '*'}]
  clusterResourceWhitelist: [{group: '*', kind: '*'}]
Y

echo '=== [2/5] Partners ApplicationSet label default ==='
R="$WORKDIR/fixture-repo"
for p in explicit-true explicit-false absent; do mkdir -p "$R/partners/$p"; done
echo 'notify: true' > "$R/partners/explicit-true/partner.yaml"
echo 'notify: false' > "$R/partners/explicit-false/partner.yaml"
echo '{}' > "$R/partners/absent/partner.yaml"
git -C "$R" init -q -b main && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m init
git daemon --reuseaddr --base-path="$WORKDIR" --export-all --listen=0.0.0.0 --port=$GITPORT &
sleep 1
GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -v : | head -1)
LABEL=$(python3 - "$INFRA_OPS/clusters/kube-dev/platform.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "ApplicationSet" and d["metadata"]["name"] == "a4i-partners":
        print(d["spec"]["template"]["metadata"]["labels"]["a4i.in/notify"])
PY
)
kubectl apply -f - >/dev/null <<Y
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: partners-label, namespace: argocd}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=default"]
  generators:
    - git:
        repoURL: git://$GW:$GITPORT/fixture-repo
        revision: main
        files: [{path: "partners/*/partner.yaml"}]
  template:
    metadata:
      name: "label-{{.path.basename}}"
      namespace: argocd
      labels:
        a4i.in/notify: '$LABEL'
    spec:
      project: default
      source: {repoURL: "https://github.com/argoproj/argocd-example-apps", targetRevision: HEAD, path: guestbook}
      destination: {server: "https://kubernetes.default.svc", namespace: "label-{{.path.basename}}"}
Y
for i in $(seq 1 40); do [ "$(kubectl get applications -n argocd -o name | grep -c '^application.argoproj.io/label-')" = 3 ] && break; sleep 3; done
lab() { kubectl get application "label-$1" -n argocd -o jsonpath='{.metadata.labels.a4i\.in/notify}' 2>/dev/null; }
[ "$(lab explicit-true)" = true ] && ok "partner with notify: true gets label true" || bad "explicit-true label is '$(lab explicit-true)'"
[ "$(lab explicit-false)" = false ] && ok "partner with notify: false gets label false" || bad "explicit-false label is '$(lab explicit-false)'"
[ "$(lab absent)" = true ] && ok "partner without notify gets label true" || bad "absent label is '$(lab absent)'"

echo '=== [3/5] Apps: labeled true, unlabeled, opted out ==='
mk() {
cat <<Y
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
  namespace: argocd
  $2
spec:
  project: default
  source: {repoURL: "https://github.com/argoproj/argocd-example-apps", targetRevision: HEAD, path: guestbook}
  destination: {server: "https://kubernetes.default.svc", namespace: $1}
  syncPolicy: {automated: {}, syncOptions: [CreateNamespace=true]}
Y
}
{ mk nn-ok 'labels: {a4i.in/notify: "true"}'; echo '---'; mk nn-unlabeled ''; echo '---'; mk nn-optout 'labels: {a4i.in/notify: "false"}'; } | kubectl apply -f - >/dev/null

echo '=== [4/5] Waiting for syncs and notifications ==='
hook() { kubectl logs deploy/webhook-mock -n argocd 2>/dev/null; }
for i in $(seq 1 60); do
  w=$(hook)
  echo "$w" | grep -q "nn-ok" && echo "$w" | grep -q "nn-unlabeled" && break
  sleep 5
done
sleep 20
w=$(hook)
c=$(kubectl logs deploy/argocd-notifications-controller -n argocd 2>/dev/null | grep "Sending notification")

echo '=== [5/5] Results ==='
echo "$w" | grep -q "nn-ok" && ok "Teams webhook for labeled true app" || bad "no webhook for nn-ok"
echo "$w" | grep -q "nn-unlabeled" && ok "Teams webhook for unlabeled app (new)" || bad "no webhook for nn-unlabeled"
echo "$w" | grep -q "nn-optout" && bad "webhook for opted-out app" || ok "no webhook for opted-out app"
# The mock SMTP has no TLS and the controller refuses unencrypted auth, so email delivery is asserted by the send attempt.
echo "$c" | grep "email" | grep -q "argocd/nn-ok" && ok "email send attempted for labeled true app" || bad "no email attempt for nn-ok"
echo "$c" | grep "email" | grep -q "argocd/nn-unlabeled" && ok "email send attempted for unlabeled app (new)" || bad "no email attempt for nn-unlabeled"
echo "$c" | grep -q "argocd/nn-optout" && bad "notification attempted for opted-out app" || ok "no notification attempted for opted-out app"

echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]
