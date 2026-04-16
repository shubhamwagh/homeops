# Metal

Bare-metal k3s cluster provisioning using k3sup and Ansible. Supports N control-plane nodes (HA) and N worker nodes.

## Prerequisites

- Nodes reachable over SSH with a known key
- Tools installed: `just tools` (installs mise, ansible, k3sup, gomplate, yq, gum, etc.)

## Recipes

| Recipe | Description |
|---|---|
| `just metal::configure` | Interactive setup — writes `inventory.yml` + `group_vars/all.yml` |
| `just metal::install` | Provision full cluster (bootstraps init node, joins servers + workers) |
| `just metal::add-node` | Join one new node interactively (server or worker) |
| `just metal::teardown` | Uninstall k3s from all nodes (after Cilium removed) |
| `just metal::copy-kubeconfig` | Copy kubeconfig from control-plane to `~/.kube/config` |
| `just metal::nodes` | `kubectl get nodes -o wide` |
| `just metal::pods` | `kubectl get pods -A -o wide` |
| `just metal::helm-list` | `helm list -A` |

## First-Time Setup

```sh
# 1. Install all tools
just tools

# 2. Interactive config (prompts for IPs, SSH key, k3s settings)
just metal::configure

# 3. Provision the cluster
just metal::install

# 4. Copy kubeconfig locally
just metal::copy-kubeconfig

# 5. Verify
just metal::nodes
```

## Configuration

`just metal::configure` writes two gitignored files:

| File | Purpose |
|---|---|
| `infrastructure/metal/inventory.yml` | Ansible inventory — node IPs + SSH config |
| `infrastructure/metal/group_vars/all.yml` | Cluster variables — token, version, VIP, etc. |

These are generated from `*.tpl` templates via `gomplate`. **Never edit them by hand** — re-run `just metal::configure` instead.

### Key Variables

| Variable | Purpose |
|---|---|
| `cluster_name` | kubeconfig context name |
| `k3s_token` | Shared cluster secret |
| `k3s_version` | Pinned k3s version (blank = latest stable) |
| `control_plane_vip` | VIP for HA; leave empty for single control-plane |
| `extra_server_args` | Extra flags for k3s server (flannel/traefik disabled by default) |
| `kubeconfig_output` | Local path where kubeconfig is written |

## HA Setup

For 3+ control-plane nodes, `just metal::configure` will prompt for a VIP (e.g. managed by kube-vip or an external load balancer). The install playbook joins secondary servers with `serial: 1` to avoid etcd split-brain.

## Adding a Node

```sh
just metal::add-node
# prompted: node IP, SSH user, role (server or worker)
```

## Teardown

```sh
# Full destroy — single command
just infra::teardown

# Or step by step:
just system::uninstall-stack   # remove all workloads
just cilium::uninstall         # remove CNI
just metal::teardown           # wipe k3s from nodes
```

`inventory.yml` and `group_vars/all.yml` are preserved after teardown so you can re-provision without re-running `just metal::configure`.
