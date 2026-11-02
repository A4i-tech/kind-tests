#!/bin/bash
# Kind test: guards for the A4i-tech/infra-ops#55 cutover (Postgres secret projection, Prune=false adoption guard, PostSync sync-wave order).
# Tested against: A4i-tech/infra-ops#55 at faa473c. Linux amd64 only.
set -euo pipefail

CLUSTER_NAME='a4i-cutover-guards'
INFRA_DIR="${INFRA_DIR:?set INFRA_DIR to your infra-ops checkout (needs partners/shiksha/superset/postgresql.yaml)}"
ARGO_VERSION="${ARGO_VERSION:-v2.14.11}"
GIT_PORT="${GIT_PORT:-9419}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

BIN=$HOME/.local/bin
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# Isolated kubeconfig, never touches the default ~/.kube/config.
export KUBECONFIG="$HOME/.kube/kind-${CLUSTER_NAME}"

WORKDIR=$(mktemp -d)
FAILS=0
RESULTS=()

cleanup() {
  [ -f "$WORKDIR/gd.pid" ] && kill "$(cat "$WORKDIR/gd.pid")" 2>/dev/null || true
  rm -rf "$WORKDIR"
  if [ "$KEEP_CLUSTER" != 1 ]; then kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true; rm -f "$KUBECONFIG"; fi
}
trap cleanup EXIT

pass() { RESULTS+=("PASS  $1  ($2)"); echo "  PASS  $1  ($2)"; }
fail() { RESULTS+=("FAIL  $1  ($2)"); echo "  FAIL  $1  ($2)"; FAILS=$((FAILS+1)); }
info() { RESULTS+=("INFO  $1  ($2)"); echo "  INFO  $1  ($2)"; }

diag() { kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{" | "}{.status.sync.status}{" | "}{.status.sync.revision}{" | "}{.status.operationState.phase}{" | "}{.status.operationState.message}{" | "}{.status.conditions[*].message}{"\n"}{end}' >&2 || true; }

wait_for() { # timeout-seconds description command...
  local t=$1 d=$2; shift 2
  local end=$((SECONDS+t))
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $end ] && { echo "TIMEOUT waiting for: $d" >&2; diag; return 1; }
    sleep 3
  done
}

echo '=== [1/6] Checking dependencies ==='
command -v kubectl &>/dev/null || { curl -sSLo "$BIN/kubectl" "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"; chmod +x "$BIN/kubectl"; }
command -v kind &>/dev/null || { curl -sSLo "$BIN/kind" https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64; chmod +x "$BIN/kind"; }
command -v git &>/dev/null && command -v docker &>/dev/null || { echo 'missing: git or docker' >&2; exit 1; }
[ -f "$INFRA_DIR/partners/shiksha/superset/postgresql.yaml" ] || { echo "no postgresql.yaml under $INFRA_DIR" >&2; exit 1; }

echo "=== [2/6] Creating kind cluster: $CLUSTER_NAME ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind export kubeconfig --name "$CLUSTER_NAME"
else
  kind create cluster --name "$CLUSTER_NAME"
fi
kubectl wait --for=condition=ready node --all --timeout=180s

echo '=== [3/6] Part A: superset Postgres with only pg-password projected ==='
kubectl create namespace superset --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic superset-app-secrets -n superset \
  --from-literal=pg-password='pgLocalTest123' --from-literal=secret-key='x' \
  --from-literal=admin-password='x' --from-literal=analytics-pg-password='x' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$INFRA_DIR/partners/shiksha/superset/postgresql.yaml"
if kubectl rollout status sts/superset-postgresql -n superset --timeout=300s; then
  pass 'A1 postgres becomes Ready' 'pg-password read from the projected file'
else
  fail 'A1 postgres becomes Ready' 'rollout did not finish'
fi
FILES=$(kubectl exec -n superset superset-postgresql-0 -- ls /opt/bitnami/postgresql/secrets/ 2>&1 | tr '\n' ' ' | sed 's/ $//')
[ "$FILES" = 'pg-password' ] && pass 'A2 only pg-password is mounted' "files: $FILES" || fail 'A2 only pg-password is mounted' "files: $FILES"
psql_in() { kubectl exec -n superset superset-postgresql-0 -- bash -c "PGPASSWORD=\$(cat \$POSTGRES_PASSWORD_FILE) psql -tA -h localhost -U \$POSTGRES_USER -d \$POSTGRES_DATABASE -c \"$1\""; }
PVC_UID_BEFORE=$(kubectl get pvc data-superset-postgresql-0 -n superset -o jsonpath='{.metadata.uid}')
psql_in "CREATE TABLE IF NOT EXISTS guard_marker(v text); INSERT INTO guard_marker VALUES ('survives');" >/dev/null
kubectl delete pod superset-postgresql-0 -n superset --wait=true >/dev/null
kubectl rollout status sts/superset-postgresql -n superset --timeout=300s >/dev/null
MARK=$(psql_in "SELECT v FROM guard_marker LIMIT 1;" 2>&1 || true)
PVC_UID_AFTER=$(kubectl get pvc data-superset-postgresql-0 -n superset -o jsonpath='{.metadata.uid}')
[ "$MARK" = 'survives' ] && pass 'A3 marker row survives pod restart' "row: $MARK" || fail 'A3 marker row survives pod restart' "got: $MARK"
[ "$PVC_UID_BEFORE" = "$PVC_UID_AFTER" ] && pass 'A4 PVC UID unchanged' "$PVC_UID_AFTER" || fail 'A4 PVC UID unchanged' "$PVC_UID_BEFORE -> $PVC_UID_AFTER"

echo "=== [4/6] Installing Argo CD $ARGO_VERSION (core) + local git repo ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/core-install.yaml" >/dev/null
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"controller.diff.server.side":"true"}}'
# core-install has no argocd-server, which is what normally creates the default project.
kubectl apply -f - <<'PROJ'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  sourceRepos: ['*']
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
PROJ
kubectl -n argocd rollout restart statefulset/argocd-application-controller >/dev/null
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s >/dev/null
kubectl -n argocd rollout status deployment/argocd-redis --timeout=300s >/dev/null

GATEWAY=$(docker network inspect kind -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | grep -E '^[0-9]+\.' | head -1)
REPO_DIR="$WORKDIR/fixture"
REPO_URL="git://${GATEWAY}:${GIT_PORT}/fixture"
mkdir -p "$REPO_DIR" && git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.email t@example.com && git -C "$REPO_DIR" config user.name tester
git -C "$REPO_DIR" commit -q --allow-empty -m init
git daemon --reuseaddr --base-path="$WORKDIR" --export-all --listen=0.0.0.0 --port="$GIT_PORT" --detach --pid-file="$WORKDIR/gd.pid" "$WORKDIR"

commit() { git -C "$REPO_DIR" add -A && git -C "$REPO_DIR" commit -q -m "$1" && git -C "$REPO_DIR" rev-parse HEAD; }

app_yaml() { # name path namespace automated(yes|no)
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: HEAD
    path: $2
  destination:
    server: https://kubernetes.default.svc
    namespace: $3
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
}

app_synced_at() { # app revision
  [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.status.sync.revision}')" = "$2" ] &&
  [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.status.operationState.phase}')" = Succeeded ] &&
  [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.status.sync.status}')" = Synced ]
}
owned_by() { [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/instance}{.metadata.labels.app\.kubernetes\.io/instance}')" = "$2" ]; }
op_done_at() { # app revision: sync operation finished at revision, Synced not required (Prune=false leaves the parent OutOfSync)
  [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.status.operationState.syncResult.revision}')" = "$2" ] &&
  [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.status.operationState.phase}')" = Succeeded ]
}
refresh() { kubectl -n argocd annotate application "$1" argocd.argoproj.io/refresh=hard --overwrite >/dev/null; }

echo '=== [5/6] Part B: Prune=false guard when Applications move between parents ==='
run_case() { # case-name guard(yes|no)
  local c=$1 guard=$2 a1="child-$1-a" a2="child-$1-b"
  mkdir -p "$REPO_DIR/parent-$c"
  for n in "$a1" "$a2"; do
    mkdir -p "$REPO_DIR/children/$n"
    cat > "$REPO_DIR/children/$n/cm.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $n-cm
  namespace: guard-test
data:
  k: v
EOF
    app_yaml "$n" "children/$n" guard-test > "$REPO_DIR/parent-$c/$n.yaml"
  done
  # Anchor keeps the parent non-empty, as a4i-platform is, so Argo does not refuse to auto-sync an empty desired state.
  cat > "$REPO_DIR/parent-$c/anchor.yaml" <<ANCHOR
apiVersion: v1
kind: ConfigMap
metadata:
  name: anchor-$c
  namespace: guard-test
ANCHOR
  local rev; rev=$(commit "$c: children under platform parent")
  app_yaml "platform-$c" "parent-$c" argocd | kubectl apply -f - >/dev/null
  wait_for 300 "platform-$c synced" app_synced_at "platform-$c" "$rev"
  for n in "$a1" "$a2"; do wait_for 300 "$n healthy" kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/"$n" --timeout=5s; done
  declare -A UID0 CM0
  for n in "$a1" "$a2"; do
    UID0[$n]=$(kubectl -n argocd get application "$n" -o jsonpath='{.metadata.uid}')
    CM0[$n]=$(kubectl -n guard-test get cm "$n-cm" -o jsonpath='{.metadata.uid}')
  done
  if [ "$guard" = yes ]; then
    kubectl -n argocd annotate application "$a1" "$a2" argocd.argoproj.io/sync-options=Prune=false --overwrite >/dev/null
  fi
  # Move the child Applications to a second parent, as superset leaves a4i-platform for partner-shiksha.
  mkdir -p "$REPO_DIR/owner2-$c"
  git -C "$REPO_DIR" mv "parent-$c/$a1.yaml" "owner2-$c/$a1.yaml"
  git -C "$REPO_DIR" mv "parent-$c/$a2.yaml" "owner2-$c/$a2.yaml"
  rev=$(commit "$c: children leave platform parent")
  refresh "platform-$c"
  wait_for 300 "platform-$c resynced" op_done_at "platform-$c" "$rev"
  local gone=0
  for n in "$a1" "$a2"; do kubectl -n argocd get application "$n" >/dev/null 2>&1 || gone=$((gone+1)); done
  app_yaml "partner-$c" "owner2-$c" argocd | kubectl apply -f - >/dev/null
  for n in "$a1" "$a2"; do
    wait_for 300 "$n adopted by partner-$c" owned_by "$n" "partner-$c"
  done
  local same=0 cmsame=0 n
  for n in "$a1" "$a2"; do
    [ "$(kubectl -n argocd get application "$n" -o jsonpath='{.metadata.uid}')" = "${UID0[$n]}" ] && same=$((same+1))
    [ "$(kubectl -n guard-test get cm "$n-cm" -o jsonpath='{.metadata.uid}')" = "${CM0[$n]}" ] && cmsame=$((cmsame+1))
  done
  echo "  case=$c guard=$guard pruned_after_platform_sync=$gone/2 application_uids_unchanged=$same/2 configmap_uids_unchanged=$cmsame/2"
  if [ "$guard" = yes ]; then
    [ "$gone" = 0 ] && [ "$same" = 2 ] && pass 'B1 guard: Applications survive platform sync, UIDs unchanged' "pruned=$gone/2 uids=$same/2" \
      || fail 'B1 guard: Applications survive platform sync, UIDs unchanged' "pruned=$gone/2 uids=$same/2"
    [ "$cmsame" = 2 ] && pass 'B2 guard: workload ConfigMaps untouched' "uids=$cmsame/2" || fail 'B2 guard: workload ConfigMaps untouched' "uids=$cmsame/2"
    kubectl -n argocd annotate application "$a1" "$a2" argocd.argoproj.io/sync-options- >/dev/null
    local left; left=$(kubectl -n argocd get application "$a1" "$a2" -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\.argoproj\.io/sync-options}{end}')
    [ -z "$left" ] && pass 'B3 guard annotation removes cleanly' 'runbook step 6 command works' || fail 'B3 guard annotation removes cleanly' "left: $left"
  else
    info 'B0 control without guard' "pruned=$gone/2 uids_unchanged=$same/2 cm_uids_unchanged=$cmsame/2"
  fi
}
kubectl create namespace guard-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null
run_case noguard no
run_case guard yes

echo '=== [6/6] Part C: PostSync sync-wave ordering ==='
run_hooks() { # case wave-annotation(yes|no)
  local c=$1 wave=$2 d="$REPO_DIR/hooks-$1"
  mkdir -p "$d"
  cat > "$d/cm.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: probe
  namespace: guard-hooks-$c
data:
  k: v
EOF
  local job
  for job in slow fast; do
    cat > "$d/$job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: guard-hooks-$c
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
$( [ "$job" = fast ] && [ "$wave" = yes ] && echo '    argocd.argoproj.io/sync-wave: "1"' )
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: main
          image: busybox:1.36
          command: ["sh", "-c", "$( [ "$job" = slow ] && echo 'sleep 25' || echo 'echo done' )"]
EOF
  done
  local rev; rev=$(commit "hooks $c")
  app_yaml "hooks-$c" "hooks-$c" "guard-hooks-$c" | kubectl apply -f - >/dev/null
  wait_for 400 "hooks-$c synced" app_synced_at "hooks-$c" "$rev"
  local ss sc fs
  ss=$(kubectl -n "guard-hooks-$c" get job slow -o jsonpath='{.status.startTime}')
  sc=$(kubectl -n "guard-hooks-$c" get job slow -o jsonpath='{.status.completionTime}')
  fs=$(kubectl -n "guard-hooks-$c" get job fast -o jsonpath='{.status.startTime}')
  echo "  case=$c slow_start=$ss slow_done=$sc fast_start=$fs"
  if [ "$wave" = yes ]; then
    [[ "$fs" > "$sc" || "$fs" = "$sc" ]] && pass 'C1 wave 1 hook starts after wave 0 hook completes' "fast_start=$fs slow_done=$sc" \
      || fail 'C1 wave 1 hook starts after wave 0 hook completes' "fast_start=$fs slow_done=$sc"
  else
    [[ "$fs" < "$sc" ]] && info 'C0 control without waves: hooks start together' "fast_start=$fs slow_done=$sc" \
      || info 'C0 control without waves: hooks did not overlap' "fast_start=$fs slow_done=$sc"
  fi
}
run_hooks nowave no
run_hooks wave yes

echo
echo '=== Summary ==='
printf '%s\n' "${RESULTS[@]}"
echo "failures: $FAILS"
[ "$FAILS" = 0 ]
