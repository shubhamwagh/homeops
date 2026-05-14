# Metal

Bare-metal node setup for the homeops k3s cluster.

## Nodes

| Role | IP | CPU | RAM | Disk |
|---|---|---|---|---|
| control-plane | 192.168.0.32 | 4 cores | 8 GB | 116 GB SSD |
| worker | 192.168.0.33 | 4 cores | 8 GB | 233 GB SSD |
| worker | 192.168.0.34 | 4 cores | 8 GB | 233 GB NVMe |

All nodes: Ubuntu 24.04 LTS, user `smw`, SSH key `~/.ssh/id_ed25519`.

## Static IPs

Set via **router DHCP reservation** (MAC → IP binding). No OS-level static IP config needed.

| Node | MAC (eno1) | IP |
|---|---|---|
| control-plane | `fc:3f:db:06:17:f1` | 192.168.0.32 |
| worker-1 | — | 192.168.0.33 |
| worker-2 | — | 192.168.0.34 |

Gateway: `192.168.0.1`

## One-time Node Setup

Run on **each node** after Ubuntu install:

```bash
# 1. Essential packages for Longhorn storage
sudo apt update && sudo apt install -y \
  open-iscsi \
  nfs-common \
  cifs-utils

# 2. Enable iSCSI (required for Longhorn)
sudo systemctl enable --now iscsid

# 3. Kernel modules for Cilium
sudo modprobe iptable_raw xt_socket
echo -e "xt_socket\niptable_raw" | sudo tee /etc/modules-load.d/cilium.conf

# 4. Disable firewall (k3s + Cilium manage their own rules)
sudo ufw disable

# 5. Passwordless sudo — required by k3sup to install k3s (replace smw with your user)
echo "smw ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/smw
```

Copy your SSH key to each node:
```bash
ssh-copy-id smw@192.168.0.32
ssh-copy-id smw@192.168.0.33
ssh-copy-id smw@192.168.0.34
```

## Verify Before Running make bootstrap

```bash
# SSH works passwordlessly to all nodes
ssh smw@192.168.0.32 hostname
ssh smw@192.168.0.33 hostname
ssh smw@192.168.0.34 hostname

# iSCSI running on all nodes
ssh smw@192.168.0.32 systemctl is-active iscsid
ssh smw@192.168.0.33 systemctl is-active iscsid
ssh smw@192.168.0.34 systemctl is-active iscsid
```

## Then

```bash
make configure   # enter node IPs, SSH key, cluster name
make bootstrap   # k3s install + cilium
make gitops      # secrets + flux bootstrap
```
