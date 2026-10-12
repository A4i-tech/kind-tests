# seeds-kind-repro

Local kind-cluster test for the full SEEDS stack (platform, websocket-service,
content-webapp, teacher-webapp). Test a feature branch end to end before
merging, without the shared kube-staging cluster or Render.

## Prerequisites

- Docker running
- `kubectl`, `python3`, `curl` on PATH (`kind` auto-downloads into `./.bin`)
- Local secrets: one JSON file per component in `SECRETS_DIR` (default
  `~/backup/seeds-staging`) — `seeds-platform-secret.json`,
  `seeds-websocket-secret.json`, `seeds-content-webapp-secret.json`,
  `seeds-teacher-webapp-secret.json`, each the full secret blob as flat
  key/value JSON. Override the directory with `SEEDS_SECRETS_DIR=...`.

## Run

```
./bootstrap.sh up
```

Brings up all 4 components at `:staging`, plus ingress-nginx. Add to your
hosts file as printed at the end, then hit `http://seeds.local:8080/health`
etc.

Test your own branch for one component:
```
docker build -t seeds-platform:mybranch <path to platform>
./bootstrap.sh load platform seeds-platform:mybranch
```

Local Mongo (Atlas isn't reachable from here):
```
./bootstrap.sh mongo
./bootstrap.sh rewire-mongo
```
Re-running `up` undoes the rewire — run `rewire-mongo` again after it.

## Other commands

`status`, `logs [comp]`, `dump [comp]`, `sh [comp]`, `restart [comp]`,
`mongo-url <block_source_id>`, `check-url '<sas url>'`, `down`.

## Isolation

Uses its own kubeconfig (`.kube/seeds-kind.kubeconfig`), never reads or
writes `~/.kube/config`, never changes your current kubectl context.

## Teardown

```
./bootstrap.sh down
```
