# shiksha-kind-test

Local kind-cluster health check for infra-ops' `partners/shiksha` stack.
Run this after any change to `partners/shiksha/apps/**` before pushing.

## Prerequisites

- Docker running
- `git`, `python3` (with PyYAML), `unzip`, `curl` on PATH
- `kubectl`/`kind` auto-install into `./tools/`
- A mongodump zip at `~/shiksha-backend-dump.zip` (override with `MONGO_DUMP_ZIP=`)
- Local secrets in `SHIKSHA_SECRETS_DIR` (default `~/backup/shiksha-staging`):
  `shiksha-be-dev-secret.json`, `shiksha-api-dev-secret.json` — full secret
  blobs as flat key/value JSON, same shape as each `*-externalsecret.yaml`'s
  `remoteRef.key`. Never fetched live from Key Vault.

## Testing a branch

`deploy` (and `all`, which calls it) checks out `SHIKSHA_BRANCH` in
`SHIKSHA_REPO_DIR` before building manifests. Defaults:
`SHIKSHA_REPO_DIR=~/infra-ops`, `SHIKSHA_BRANCH=a4i/main`. This does a
`git fetch` + hard reset in `SHIKSHA_REPO_DIR` — refuses if that checkout
has uncommitted changes.
```
SHIKSHA_BRANCH=fix/shiksha-fe-runtime-env-574 ./run.sh all
```

## CI mode

Set `SHIKSHA_BE_IMAGE`, `SHIKSHA_API_IMAGE` and `SHIKSHA_FE_IMAGE` to local docker
image names. `deploy` loads them into kind and deploys them instead of the registry
`:staging` images. Set `SKIP_MONGO_RESTORE=1` to start an empty mongo and seed it
yourself, with no dump zip.

## Full run

```
./run.sh all        # cluster, secrets, mongo+restore, deploy, rewire-mongo, status
```
Then in one shell:
```
./run.sh forward
```
and in another:
```
./run.sh test         # fe serves, env.js rendered, /api proxies to be
./run.sh login-test   # full OTP login against restored test data
```

Test user in the seed dump: phone `9999999999`, pin `7476`.

## Other commands

`status`, `kubectl <args>` (passthrough, isolated kubeconfig guaranteed).

## Teardown

```
./run.sh down
```

## Why local mongo instead of the real Atlas cluster

Atlas isn't reachable from this sandbox's egress (IP allowlist). A
standalone `mongo:6` pod, seeded via `mongorestore` from the dump, stands
in for it — `MONGO_URL` in `shiksha-be-secret` is repointed via
`rewire-mongo`. Everything else (LLM_API_BASE_URL, JWT_SECRET, etc.) is
cloned as-is from the local secret file.

## What's skipped vs. the real cluster

`ExternalSecret`, `Certificate`, and the fe `Ingress` are filtered out of
the applied manifests — their CRDs/controller aren't in kind. Port-forward
stands in for ingress.

## Isolation

Uses its own kubeconfig (`.kubeconfig-kind`, next to this script), never
reads or writes `~/.kube/config`, never changes your current kubectl
context.
