# argocd-drift

Why ArgoCD notifications fire on commits that do not touch an app, and the cluster-wide fix.

Apps whose Git manifests omit fields that the API server or a CRD defaults (ESO `conversionStrategy`, StatefulSet `volumeClaimTemplates`) stay `OutOfSync`. With `selfHeal`, each new git revision re-syncs them, and `on-sync-succeeded` fires once per revision.

| Script | Shows |
|---|---|
| `run.sh` | Reproduces the drift and the extra sync per unrelated commit, then checks per-app `ignoreDifferences` fixes it |
| `run-ssd.sh` | Same fixtures with `controller.diff.server.side=true` and no extra ignores. Zero drift, no resync, real changes still sync |

Same versions as kube-dev: ArgoCD chart 7.9.1 (2.14.x), ESO v0.10.3 CRDs. Fixtures are served by a local git daemon on the kind network.

```
./argocd-drift/run-ssd.sh            # create cluster, run 6 checks, keep the cluster
REUSE=1 ./argocd-drift/run-ssd.sh    # rerun on the kept cluster
./argocd-drift/run-ssd.sh down       # delete it
```

Needs docker, kind, kubectl, helm, git. Uses its own kubeconfig, never `~/.kube/config`.
