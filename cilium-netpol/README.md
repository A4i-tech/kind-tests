# cilium-netpol

Checks the existing infra-ops NetworkPolicies under Cilium, for A4i-tech/.github#740.

- 3-node kind cluster, Cilium 1.17.6, pod CIDR 10.244.0.0/16, service CIDR 10.0.0.1 as on AKS
- Mock public host on 198.51.100.10, IMDS on 169.254.169.254 on every node
- Phase 1: no policies, confirms today's kube-dev (everything reachable)
- Phase 2: applies all 75 policies from infra-ops, runs 93 checks from probe pods labelled like the real workloads (allow/deny, DNS, kubelet probes)

```
INFRA_OPS=/path/to/infra-ops ./run.sh        # KEEP=1 to keep the cluster, REUSE=1 to reuse it
./run.sh down
```

Linux amd64 only. Tested against infra-ops 19448f7.
