# Homepage

Cluster dashboard showing all services with status indicators and resource metrics. Backed by `metrics-server` for CPU/memory data.

## Prerequisites

- Gateway installed (`just gateway::install`)

## Install

```sh
just homepage::install
```

What happens:
1. Installs `metrics-server` in `kube-system` (with `--kubelet-insecure-tls` for k3s)
2. Deploys Homepage in the `homepage` namespace with RBAC to read cluster resources

## Recipes

| Recipe | Description |
|---|---|
| `just homepage::install` | Install Homepage + metrics-server |
| `just homepage::uninstall` | Remove Homepage and metrics-server |

## URLs

| | URL |
|---|---|
| Homepage | `https://homepage.home.didcot` |
| Direct (no DNS) | `http://192.168.0.7` |

## Configuration

Homepage configuration lives in `configmap.yaml`. Edit to add/remove services, change layout, or update service URLs. Apply with:

```sh
kubectl apply -f infrastructure/system/homepage/configmap.yaml
kubectl rollout restart deployment/homepage -n homepage
```
