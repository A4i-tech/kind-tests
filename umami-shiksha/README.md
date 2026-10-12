# umami-shiksha-kind-test

Local kind-cluster test: deploys `apps/umami` + `partners/shiksha-fe` together,
wires umami tracking into shiksha-fe, smoke tests both. Confirms umami
analytics actually captures shiksha-fe pageviews end to end.

## Prerequisites

- Docker running
- `python3` with PyYAML, `curl`
- `kubectl`/`kind` auto-install to `~/.local/bin`
- Linux amd64 (WSL included)

## Run

```
INFRA_DIR=/path/to/infra-ops ./umami-shiksha-kind-test.sh
```

`INFRA_DIR` must point at a checkout with `apps/umami/` (targets
A4i-tech/infra-ops#44 — the older `platform/umami/` from PR #36 is
superseded and no longer on `a4i/main`).

be/api come up with dummy secrets and are NOT expected to work — only
shiksha-fe's static traffic is exercised, which is enough to fire
pageviews at umami.

## What it does

1. Creates an isolated kind cluster (own kubeconfig, `~/.kube/kind-<cluster>`).
2. Deploys `apps/umami`, filtering out `ExternalSecret`/`Certificate`/`Ingress`
   (no ESO/cert-manager/ingress controller in kind) and stripping
   `storageClassName` off the Postgres PVC (Azure-specific class doesn't
   exist in kind, falls back to kind's own default).
3. Registers a test website via the umami API.
4. Deploys shiksha-fe with an added initContainer that copies the image's
   baked-in `/srv` out, patches `index.html` to inject the umami tracking
   script tag, then mounts the patched copy back over `/srv`.
5. Prints port-forwarded URLs for both.

## Teardown

```
kind delete cluster --name umami-shiksha-sandbox
rm -f ~/.kube/kind-umami-shiksha-sandbox
```
