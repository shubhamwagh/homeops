# Cilium

CNI, kube-proxy replacement, L2 load balancer, and Gateway API implementation for the cluster. Must be installed before any other system component.

## Prerequisites

- k3s cluster provisioned (`just metal::install`)
- `just metal::configure` run (writes `inventory.yml` and `group_vars/all.yml`)

## Install

```sh
just cilium::install
```

What happens:
1. Installs Gateway API CRDs (experimental channel, v1.2.1)
2. Flushes stale iptables chains from any previous Cilium install
3. Installs Cilium via Helm at v1.17.3 in `kube-system`
4. Applies `CiliumL2AnnouncementPolicy` and `CiliumLoadBalancerIPPool`
5. Waits for the Cilium DaemonSet to be ready

## Recipes

| Recipe | Description |
|---|---|
| `just cilium::install` | Install / upgrade Cilium |
| `just cilium::uninstall` | Remove Cilium (WARNING: takes down cluster CNI) |

## L2 IP Pool

Services of type `LoadBalancer` get IPs from `192.168.0.2 – 192.168.0.14`. These are announced via L2 (ARP) — no BGP required.

## Uninstall Warning

Removing Cilium removes the cluster's CNI — all pod networking stops. Only do this as part of a full cluster teardown.

```sh
just cilium::uninstall
```
