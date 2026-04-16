# Longhorn

Distributed block storage for the cluster. Provides the default `StorageClass` used by all stateful workloads (PostgreSQL, Vault, AdGuard, etc.). 2 replicas across nodes.

## Prerequisites

- k3s cluster provisioned (`just metal::install`)
- Cilium installed (`just cilium::install`)

## Install

```sh
just longhorn::install
```

What happens:
1. Runs Ansible playbook `prerequisites.yml` to install iSCSI tools and configure multipath on all nodes
2. Installs Longhorn v1.7.2 via Helm in `longhorn-system`
3. Waits for the driver deployer, CSI provisioner, and CSI plugin DaemonSet to be ready

## Recipes

| Recipe | Description |
|---|---|
| `just longhorn::install` | Install Longhorn + node prerequisites |
| `just longhorn::uninstall` | Remove Longhorn and all volumes **(destructive)** |

## Uninstall Warning

Removing Longhorn destroys all PVCs using the `longhorn` StorageClass. Back up any data first.

```sh
just longhorn::uninstall
```

## UI

`https://longhorn.home.didcot` (available after `just gateway::install`)
