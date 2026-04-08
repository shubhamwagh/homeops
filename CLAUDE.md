# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Bare-metal k3s cluster provisioning using k3sup and Ansible. Supports N control-plane nodes (HA) and N worker nodes. The user-facing interface is entirely `just` recipes organised as modules.

## Running Things

```bash
just tools              # install all tools via mise (first-time setup)
just k3s::configure     # interactive setup → writes inventory + group_vars
just k3s::install       # provision full cluster
just k3s::add-node      # join one new node (server or worker)
just k3s::teardown      # uninstall k3s from all nodes
just k3s::nodes         # kubectl get nodes -o wide
just k3s::helm-list     # helm list -A
just k3s::copy-kubeconfig  # copy kubeconfig to ~/.kube/config
```

## Tool Stack

| Tool | Role |
|---|---|
| `mise` | Pins all tool versions (see `mise.toml`) |
| `just` | Task runner — the only interface a user needs |
| `gum` | Interactive terminal UI for `just k3s::configure` |
| `gomplate` | Renders all `.tpl` templates — OS autoinstall, dnsmasq, iPXE, k3s inventory + vars |
| `yq` | Reads values from generated `inventory.yml` / `group_vars/all.yml` |
| `ansible` | Executes playbooks over SSH to provision nodes |
| `k3sup` | Called by Ansible (delegate_to localhost) to install/join k3s |
| `kubectl` / `helm` | Post-install cluster interaction |

## Architecture

- **Module-based Justfile** — recipes are split into per-component `.just` files (`k3s.just`, etc.) and imported via `mod` in the root `Justfile`.
- **No shell script files** — all logic lives in Ansible playbooks or inline `just` recipes.
- **Ansible runs locally** — all playbook tasks use `delegate_to: localhost` and invoke `k3sup` locally, which SSHes into the target nodes.
- **Config is generated** — `infrastructure/k3s/inventory.yml` and `infrastructure/k3s/group_vars/all.yml` are written by `just k3s::configure` and are gitignored. Never edit them by hand.
- **HA control plane** — `install.yml` uses `serial: 1` when joining secondary control-plane nodes to avoid etcd split-brain. Workers join in parallel.
- **Idempotent** — playbooks check `systemctl is-active k3s / k3s-agent` before calling k3sup; re-running `just k3s::install` is safe.
- **Teardown order** — workers → secondary servers → init node. Init node is always last.

## Project Structure

```
homeops/
├── mise.toml                   # tool version pins
├── Justfile                    # root — imports modules, exposes just tools
├── infrastructure/k3s/mod.just # k3s module recipes
└── infrastructure/
    └── k3s/
        ├── ansible.cfg             # SSH pipelining, fact caching, yaml output
        ├── inventory.yml.tpl       # gomplate template → inventory.yml (gitignored)
        ├── inventory.yml           # generated (gitignored)
        ├── group_vars/
        │   ├── all.yml.tpl         # gomplate template → all.yml (gitignored)
        │   └── all.yml             # generated (gitignored)
        └── playbooks/
            ├── install.yml     # bootstrap + join N servers + N workers + verify
            ├── add-node.yml    # join a single node with vars_prompt
            └── teardown.yml    # confirm + uninstall in safe order
```

## Key Variables (group_vars/all.yml)

| Variable | Purpose |
|---|---|
| `cluster_name` | kubeconfig context name |
| `k3s_token` | Shared cluster secret |
| `k3s_version` | Pinned version, empty = latest stable |
| `control_plane_vip` | VIP for HA; empty for single control-plane |
| `extra_server_args` | Appended to k3sup `--k3s-extra-args` for servers |
| `extra_agent_args` | Appended to k3sup `--k3s-extra-args` for agents |
| `kubeconfig_output` | Local path where kubeconfig is written |
