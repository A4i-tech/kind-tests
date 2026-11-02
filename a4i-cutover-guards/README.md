# a4i-cutover-guards

Local kind-cluster test for the Superset cutover in A4i-tech/infra-ops#55. It
checks three things the runbook depends on, using the real manifest where it
matters and stand-in workloads where only Argo CD behaviour is in question.

## Prerequisites

- Docker running
- `git`, `curl`
- `kubectl`/`kind` auto-install to `~/.local/bin`
- Linux amd64 (WSL included)

## Run

```
INFRA_DIR=/path/to/infra-ops ./run.sh
```

`INFRA_DIR` must point at a checkout with `partners/shiksha/superset/postgresql.yaml`.
Set `KEEP_CLUSTER=1` to keep the cluster for debugging, otherwise it is deleted on exit.

## What it checks

| Part | Check | Uses |
|---|---|---|
| A | Postgres starts with only `pg-password` projected from `superset-app-secrets`, the marker row and PVC survive a pod restart | real `postgresql.yaml` |
| B | Without `Prune=false`, a parent that loses two child Applications prunes them and the UIDs change. With it, nothing is pruned, UIDs are unchanged, and the annotation removes cleanly | stand-in Applications, Argo CD v2.14.11 |
| C | A `sync-wave: "1"` PostSync hook starts only after the wave 0 hook completes. A no-wave control shows both starting together | stand-in Jobs |

Part B and C do not exercise the real Superset sync. Argo CD runs from
`core-install.yaml`, so the script creates the `default` AppProject itself, and
uses a local `git daemon` on the kind network gateway as the repo.

## Notes

- With `Prune=false` set, the parent shows `OutOfSync` for the guarded
  Applications until the annotation is removed. The script waits for the sync
  operation to finish instead of for `Synced`.
- kind's Argo CD labels tracked resources `app.kubernetes.io/instance`, while
  kube-dev uses `argocd.argoproj.io/instance`. The script accepts either.
- Isolated kubeconfig `~/.kube/kind-a4i-cutover-guards`, never touches the default.
