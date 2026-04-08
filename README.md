# homeops

Bare-metal [k3s](https://k3s.io) cluster provisioning — from blank hardware to a running cluster. Covers the full stack:

1. **OS provisioning** — PXE boot + Ubuntu 24.04 autoinstall (unattended, per-node config)
2. **k3s cluster** — N control-plane nodes (HA) + N worker nodes via [k3sup](https://github.com/alexellis/k3sup) + Ansible

---

## Prerequisites

You need [mise](https://mise.jdx.dev) and one of the following on your local machine. Everything else is managed by mise.

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

### Install PXE prerequisites

```bash
# macOS
brew install dnsmasq xorriso wakeonlan

# Linux
sudo apt install -y dnsmasq xorriso wakeonlan
```

### Install all tools

```bash
mise install   # bootstrap (first time, before just is available)
just tools     # subsequent runs
```

Installs via mise: `just`, `gum`, `yq`, `gomplate`, `kubectl`, `helm`, `ansible`, `k3sup`.

---

## Full Flow: Blank Hardware → Running Cluster

```
just os::configure   →   just os::download   →   just os::start   →   just os::wake
                                                                              ↓
                                                                   (nodes power on + PXE boot)
                                                                              ↓
                                                          just os::watch   →   just os::stop
        ↓
just k3s::configure  →   just k3s::install
```

---

## Phase 1 — OS Provisioning

### Step 1 — Get the MAC address of each node

#### Node running Ubuntu

```bash
ssh user@<node-ip> "ip link show | awk '/^[0-9]+:/{iface=\$2} /link\/ether/{print iface, \$2}'"
```

Use the MAC of the physical ethernet interface (e.g. `enp0s31f6`), not virtual ones.

#### Node running Windows

Open Command Prompt or PowerShell:

```cmd
ipconfig /all
```

Find `Physical Address` under `Ethernet adapter Ethernet`. Format is `AA-BB-CC-DD-EE-FF` — enter it with colons (`aa:bb:cc:dd:ee:ff`) when prompted.

#### Brand new machine (no OS)

Power on → press **F10** (HP) to enter BIOS → navigate to **Network / LAN settings**. The MAC address is shown there.

---

### Step 2 — Enable PXE boot in BIOS

While in BIOS (F10 on HP):

- Enable **Network Boot** under Boot Options
- Use **F12** at boot for a one-time network boot menu (recommended — leaves disk boot as default)

---

### Step 3 — Configure OS provisioning

```bash
just os::configure
```

Interactive prompts for:

- PXE server IP + network interface (auto-detected)
- SSH username, public key path, password
- Gateway, DNS, subnet, locale, keyboard layout, timezone
- Per-node: hostname, IP, MAC address, architecture

Generates per-node Ubuntu autoinstall configs and dnsmasq config. Nothing is installed yet.

---

### Step 4 — Download Ubuntu boot files

```bash
just os::download
```

Downloads the Ubuntu 24.04 live server ISO, extracts `vmlinuz` + `initrd` for each required architecture using `xorriso`, then deletes the ISO. Also downloads iPXE binaries.

---

### Step 5 — Start the PXE server

```bash
just os::start
```

Starts:
- `dnsmasq` in proxy DHCP mode — coexists with your existing router, only intercepts PXE requests
- Python HTTP server on port 8080 — serves kernel, initrd, and autoinstall configs

---

### Step 6 — Boot each node

Power on (or reboot) each machine. Press **F12** at the HP logo → select **Network Boot / PXE**.

Each node will automatically:
1. Get a DHCP proxy response from dnsmasq
2. Load the iPXE bootloader over TFTP
3. Download the Ubuntu kernel + initrd over HTTP
4. Fetch its per-node autoinstall config (matched by MAC address)
5. Install Ubuntu unattended and reboot

> **Note:** This wipes the disk. Any existing OS will be replaced.

---

### Step 7 — Watch progress

```bash
just os::watch
```

Tails PXE + HTTP logs and polls SSH until each node comes up. Prints a ✓ when reachable.

---

### Step 8 — Stop the PXE server

```bash
just os::stop
```

---

## Phase 2 — k3s Cluster

### Step 1 — Configure the cluster

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

### Step 2 — Provision the cluster

```bash
just k3s::install
```

Runs the Ansible playbook which:
1. Bootstraps the first control-plane node with `--cluster-init`
2. Joins additional control-plane nodes one at a time (serial, avoids etcd split-brain)
3. Joins all worker nodes in parallel
4. Waits until all nodes report `Ready`
5. Copies kubeconfig to `~/.kube/config`

```bash
kubectl get nodes -o wide
```

---

## All `just` Recipes

```
just tools                  # install all tools via mise

just os::configure          # generate per-node autoinstall configs + dnsmasq config
just os::download           # fetch iPXE binaries + Ubuntu netboot files
just os::start              # start dnsmasq (PXE/TFTP) + HTTP server
just os::stop               # stop PXE server
just os::status             # show PXE server status
just os::wake               # send Wake-on-LAN packets to all configured nodes
just os::watch              # tail logs + poll nodes for SSH availability
just os::add-node           # generate config for one new node

just k3s::configure         # interactive setup → writes inventory + group_vars
just k3s::install           # provision full cluster
just k3s::add-node          # join one new node (server or worker)
just k3s::teardown          # uninstall k3s from all nodes
just k3s::nodes             # kubectl get nodes -o wide
just k3s::helm-list         # helm list -A
just k3s::copy-kubeconfig   # copy kubeconfig from control-plane to ~/.kube/config
```

---

## Adding a New Node to an Existing Cluster

Follow steps 1–2 from Phase 1 to get the MAC address and enable PXE, then:

```bash
just os::add-node    # generate config for the new node
just os::status      # check if PXE server is running
just os::start       # start if not
# boot the node → F12 → Network Boot
just os::watch       # wait for Ubuntu install to finish
just k3s::add-node   # join node to the running cluster
```

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
    ├── os/
    │   ├── mod.just                # os:: recipes
    │   ├── autoinstall/
    │   │   ├── user-data.tpl       # gomplate template — Ubuntu autoinstall config
    │   │   └── meta-data           # empty cloud-init meta-data
    │   ├── boot/
    │   │   └── ipxe.script         # gomplate template — iPXE boot script
    │   ├── dnsmasq.conf.tpl        # gomplate template — dnsmasq proxy DHCP config
    │   ├── nodes/                  # generated per-node configs (gitignored)
    │   └── tftp/                   # downloaded iPXE binaries + rendered boot.ipxe (gitignored)
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
