# kind-tests

Local kind-cluster test scripts for A4i-tech partner/platform apps. Test an
infra-ops change end to end before merging, without the shared kube-dev
cluster.

| Folder | Tests |
|---|---|
| [`umami-shiksha/`](umami-shiksha/) | apps/umami + partners/shiksha-fe together (umami tracking wired into shiksha-fe) |
| [`shiksha-kind-test/`](shiksha-kind-test/) | partners/shiksha (api/be/fe) in isolation, full login flow against a local Mongo |
| [`seeds-kind-repro/`](seeds-kind-repro/) | partners/seeds, all 4 components, against real staging-shaped config |

## Prerequisites

- Docker running
- `python3` with PyYAML, `curl`, `unzip`, `git`
- `kubectl`/`kind` auto-install per script, nothing installed system-wide
- Linux amd64 (WSL included) — the kind/kubectl downloads are hardcoded to
  that platform

## Secrets

Every script reads secrets from local JSON files, never a live Azure Key
Vault read — each folder's own README documents the expected directory and
file names, overridable via an env var. Populate those files yourself;
nothing here fetches credentials over the network.

## Isolation

Every script uses its own kubeconfig, never `~/.kube/config`, and never
switches your current kubectl context — safe to run alongside normal
kube-dev work in another shell.

## Running a script

See each folder's own README for usage, env vars, and what it tests.

## Adding a script

One folder per test, named after what it deploys, its own cluster name and
kubeconfig, a `# Tested against:`-style header noting what infra-ops state
it was last run against. Goes in through a PR.

## Versioning

Plain git history — every change lands via PR with a commit message
explaining what changed and why. No separate CHANGELOG, no custom version
scheme. Tag a commit only if someone needs to pin an older version.
