# notify-all

Checks the "notify every app" change in infra-ops: the `a4i.in/notify!=false` subscription selector in `platform/argocd-notifications/notifications-cm.yaml` and the partners ApplicationSet label default in `clusters/kube-dev/platform.yaml`.

- Partner with `notify: true`, `notify: false` and no key gets label `true`, `false`, `true`
- Labeled, unlabeled and opted-out apps: the first two reach the Teams webhook and get an email attempt, the opted-out one gets neither

Mock Teams webhook and SMTP, ArgoCD chart 7.9.1. Email is asserted by the controller's send attempt, because the mock SMTP has no TLS and the controller refuses unencrypted auth.

```
INFRA_OPS=~/infra-ops ./notify-all/run.sh            # create cluster, run 9 checks, keep the cluster
REUSE=1 INFRA_OPS=~/infra-ops ./notify-all/run.sh    # rerun on the kept cluster
./notify-all/run.sh down                             # delete it
```

Needs docker, kind, kubectl, helm, git, internet access (the test apps sync from argocd-example-apps). Uses its own kubeconfig, never `~/.kube/config`.
