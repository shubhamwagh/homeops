# homeops

Bare-metal [k3s](https://k3s.io) cluster provisioning — from fresh Ubuntu nodes to a running cluster. Supports N control-plane nodes (HA) and N worker nodes via [k3sup](https://github.com/alexellis/k3sup) + Ansible.

---

## Prerequisites

You need [mise](https://mise.jdx.dev) on your local machine. Everything else is managed by mise.

### Install mise

```bash
# macOS
brew install mise

# Linux
curl https://mise.run | sh
```

Activate in your shell:

```bash
# bash
echo 'eval "$(mise activate bash)"' >> ~/.bashrc

# zsh
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
```

### Install all tools

```bash
mise install   # bootstrap (first time, before just is available)
just tools     # subsequent runs
```

Installs via mise: `just`, `gum`, `yq`, `gomplate`, `kubectl`, `helm`, `ansible`, `k3sup`.

---

## Flow

```
just k3s::configure  →  just k3s::install  →  kubectl get nodes -o wide
```

---

## Step 1 — Configure the cluster

```bash
just k3s::configure
```

Interactive prompts for:

- SSH user, key path, port
- Cluster name, k3s version, cluster token (auto-generated if blank)
- Extra server/agent args (defaults to a minimal install — no flannel, traefik, servicelb, metrics-server, or cloud controller — ready for Cilium)
- Control-plane node IPs (space-separated — first is the bootstrap node)
- Worker node IPs (optional)
- Virtual IP for HA (required if >1 control-plane node)
- kubeconfig output path

Renders `inventory.yml` and `group_vars/all.yml` via gomplate (both gitignored — contain secrets).

---

## Step 2 — Provision the cluster

```bash
just k3s::install
```

Runs the Ansible playbook which:
1. Bootstraps the first control-plane node with `--cluster-init`
2. Joins additional control-plane nodes one at a time (serial, avoids etcd split-brain)
3. Joins all worker nodes in parallel
4. Waits until all nodes report `Ready`
5. Copies kubeconfig to the configured output path

```bash
kubectl get nodes -o wide
```

---

## All `just` Recipes

```
just tools                  # install all tools via mise

just k3s::configure         # interactive setup → writes inventory + group_vars
just k3s::install           # provision full cluster
just k3s::add-node          # join one new node (server or worker)
just k3s::teardown          # uninstall k3s from all nodes
just k3s::nodes             # kubectl get nodes -o wide
just k3s::helm-list         # helm list -A
just k3s::copy-kubeconfig   # copy kubeconfig from control-plane to ~/.kube/config
```

---

## Adding a Node to an Existing Cluster

```bash
just k3s::add-node
```

Prompts for the new node's IP and role (server or worker), then joins it to the running cluster.

---

## Teardown

```bash
just k3s::teardown
```

Prompts for confirmation (`yes`), then uninstalls k3s in safe order:
1. Worker nodes
2. Secondary control-plane nodes
3. Init control-plane node (last)

Also removes the local kubeconfig and `~/.kube/config`.

---

## HA Setup Notes

When using multiple control-plane nodes you need a Virtual IP (VIP) in front of all of them. Common options:

| Tool | Notes |
|---|---|
| [kube-vip](https://kube-vip.io) | Runs inside the cluster, no extra infra |
| keepalived | Classic Linux VIP, runs on the nodes |
| External LB | HAProxy, nginx, cloud LB |

Set this IP as the VIP during `just k3s::configure`. It is added as `--tls-san` automatically so the API server certificate is valid when accessed via the VIP.

---

## Default k3s Server Args

```
--write-kubeconfig-mode=644
--disable=flannel,local-storage,metrics-server,servicelb,traefik
--flannel-backend=none
--disable-network-policy
--disable-cloud-controller
--disable-kube-proxy
```

Leaves the cluster ready for [Cilium](https://cilium.io) — handles pod networking, network policy, load balancing, and kube-proxy replacement via eBPF.

---

## Project Structure

```
homeops/
├── mise.toml                       # tool version pins
├── Justfile                        # root — imports modules
└── infrastructure/
    └── k3s/
        ├── mod.just                # k3s:: recipes
        ├── ansible.cfg             # SSH pipelining, fact caching, yaml output
        ├── inventory.yml.tpl       # gomplate template → inventory.yml
        ├── inventory.yml           # generated (gitignored)
        ├── group_vars/
        │   ├── all.yml.tpl         # gomplate template → all.yml
        │   └── all.yml             # generated (gitignored)
        └── playbooks/
            ├── install.yml         # bootstrap + join N servers + N workers + verify
            ├── add-node.yml        # join a single node
            └── teardown.yml        # uninstall in safe order
```
