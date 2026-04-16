# SkyPilot

SkyPilot API server for running AI/ML workloads on the cluster. Provides a unified interface for job scheduling and cloud resource management.

## Prerequisites

- k3s cluster provisioned
- Cilium installed (for LoadBalancer IP)

## Install

```sh
just skypilot::install
```

Installs SkyPilot v0.12.0 via Helm in the `skypilot` namespace.

## Recipes

| Recipe | Description |
|---|---|
| `just skypilot::install` | Install SkyPilot API server |
| `just skypilot::uninstall` | Remove SkyPilot |

## URLs

| | URL |
|---|---|
| SkyPilot UI | `https://skypilot.home.didcot` |
| Direct (no DNS) | `http://192.168.0.8` |

## CLI Setup

After install, configure the SkyPilot CLI to use the cluster API:

```sh
sky api login -e http://192.168.0.8
```

Or with HTTPS (after DNS and CA are configured):

```sh
sky api login -e https://skypilot.home.didcot
```
