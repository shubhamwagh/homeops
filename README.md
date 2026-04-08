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

Installs: `just`, `gum`, `yq`, `gomplate`, `kubectl`, `helm`, `ansible`, `k3sup`.

---

## Flow

```
just metal::configure  →  just metal::install  →  just system::install
```

- **metal** — provisions bare-metal nodes with k3s
- **system** — installs foundational cluster infrastructure (Cilium CNI)

---

## metal

### Configure

```bash
just metal::configure
```

Interactive prompts for SSH access, k3s version, cluster token, node IPs, and HA VIP. Writes `inventory.yml` and `group_vars/all.yml` (both gitignored).

### Install

```bash
just metal::install
```

Runs the Ansible playbook:

1. Bootstraps the first control-plane node with `--cluster-init`
2. Joins additional control-plane nodes one at a time (avoids etcd split-brain)
3. Joins all worker nodes in parallel
4. Waits until all nodes report `Ready`

### Other recipes

```
just metal::add-node          # join one new node (server or worker)
just metal::teardown          # uninstall k3s from all nodes
just metal::nodes             # kubectl get nodes -o wide
just metal::helm-list         # helm list -A
just metal::copy-kubeconfig   # copy kubeconfig to ~/.kube/config
```

---

## system

```bash
just system::install
```

Installs foundational cluster components. Must run after `just metal::install`.

| Component | Purpose |
|---|---|
| [Cilium](https://cilium.io) | CNI + kube-proxy replacement via eBPF |

Individual recipes:

```
just system::cilium   # install / upgrade Cilium only
```

---

## HA Setup Notes

When using multiple control-plane nodes you need a Virtual IP (VIP). Common options:

| Tool | Notes |
|---|---|
| [kube-vip](https://kube-vip.io) | Runs inside the cluster, no extra infra |
| keepalived | Classic Linux VIP, runs on the nodes |
| External LB | HAProxy, nginx, cloud LB |

Set the VIP during `just metal::configure`. It is added as `--tls-san` so the API server certificate covers it.

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

Flannel and kube-proxy are disabled — Cilium replaces both.

---

## Project Structure

```
homeops/
├── mise.toml
├── Justfile                              # imports metal + system modules
└── infrastructure/
    ├── metal/                            # bare-metal k3s provisioning
    │   ├── mod.just
    │   ├── ansible.cfg
    │   ├── inventory.yml.tpl
    │   ├── group_vars/
    │   │   └── all.yml.tpl
    │   └── playbooks/
    │       ├── install.yml
    │       ├── add-node.yml
    │       └── teardown.yml
    └── system/                           # cluster infrastructure
        └── mod.just
```
