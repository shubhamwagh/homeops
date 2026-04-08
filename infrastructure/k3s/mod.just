# =============================================================
# k3s.just — bare-metal k3s cluster operations
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

K3S_DIR   := justfile_directory() / "infrastructure" / "k3s"
INVENTORY := K3S_DIR / "inventory.yml"
PLAYBOOKS := K3S_DIR / "playbooks"
VARS_FILE := K3S_DIR / "group_vars" / "all.yml"

# Interactive cluster setup → writes inventory + group_vars
configure:
    #!/usr/bin/env bash
    set -euo pipefail

    gum style \
      --border double --border-foreground 212 \
      --padding "1 4" --margin "1 0" \
      --bold "k3s Cluster Configuration"

    # ── SSH ───────────────────────────────────────────────────
    gum style --bold --foreground 212 "\n▸ SSH Access"
    SSH_USER=$(gum input --prompt "SSH user › "     --value "ubuntu")
    SSH_KEY=$(gum input  --prompt "SSH key path › " --value "~/.ssh/id_ed25519")
    SSH_PORT=$(gum input --prompt "SSH port › "     --value "22")

    # ── k3s settings ──────────────────────────────────────────
    gum style --bold --foreground 212 "\n▸ k3s Settings"
    CLUSTER_NAME=$(gum input --prompt "Cluster name › " --value "homelab-cluster")
    K3S_VERSION=$(gum input  --prompt "k3s version (blank = latest) › " --placeholder "v1.35.1+k3s1")
    K3S_TOKEN=$(gum input    --prompt "Cluster token › " --placeholder "strong random secret" --password)
    [[ -z "$K3S_TOKEN" ]] && K3S_TOKEN=$(openssl rand -hex 16) && \
      gum style --foreground 244 "  · token auto-generated"

    EXTRA_SERVER=$(gum input --prompt "Extra server args › " --value="--write-kubeconfig-mode=644 --disable=flannel,local-storage,metrics-server,servicelb,traefik --flannel-backend=none --disable-network-policy --disable-cloud-controller --disable-kube-proxy")
    EXTRA_AGENT=$(gum input  --prompt "Extra agent args › "  --placeholder "(leave empty)")
    KUBECONFIG_OUT=$(gum input --prompt "kubeconfig output path › " --value "{{justfile_directory()}}/kubeconfig")

    # ── control-plane nodes ───────────────────────────────────
    gum style --bold --foreground 212 "\n▸ Control Plane Nodes"
    gum style --foreground 244 "  Space-separated IPs — first = bootstrap node"
    CP_NODES=$(gum input --prompt "Control-plane IPs › " --placeholder "192.168.1.10 192.168.1.11 192.168.1.12")
    [[ -z "$CP_NODES" ]] && { gum style --foreground 196 "At least one control-plane IP required"; exit 1; }

    CP_COUNT=$(echo "$CP_NODES" | wc -w | tr -d ' ')

    CP_VIP=""
    if [[ "$CP_COUNT" -gt 1 ]]; then
      gum style --bold --foreground 212 "\n▸ HA Virtual IP"
      gum style --foreground 244 "  Required for HA (kube-vip / keepalived / external LB)"
      CP_VIP=$(gum input --prompt "Control plane VIP › " --placeholder "192.168.1.100")
      [[ -z "$CP_VIP" ]] && { gum style --foreground 196 "VIP cannot be empty for HA"; exit 1; }
    fi

    # ── worker nodes ──────────────────────────────────────────
    gum style --bold --foreground 212 "\n▸ Worker Nodes"
    gum style --foreground 244 "  Space-separated IPs — leave empty for control-plane-only"
    WRK_NODES=$(gum input --prompt "Worker IPs › " --placeholder "192.168.1.20 192.168.1.21")

    # ── write inventory.yml + group_vars/all.yml ─────────────
    gum style --bold --foreground 212 "\n▸ Writing files"

    mkdir -p "{{K3S_DIR}}/group_vars"

    export SSH_USER SSH_KEY SSH_PORT CP_NODES WRK_NODES
    gomplate -f "{{K3S_DIR}}/inventory.yml.tpl" -o "{{INVENTORY}}"
    chmod 600 "{{INVENTORY}}"
    gum style --foreground 46 "  ✓ inventory.yml"

    export CLUSTER_NAME K3S_TOKEN K3S_VERSION CP_VIP EXTRA_SERVER EXTRA_AGENT KUBECONFIG_OUT
    gomplate -f "{{K3S_DIR}}/group_vars/all.yml.tpl" -o "{{VARS_FILE}}"
    chmod 600 "{{VARS_FILE}}"
    gum style --foreground 46 "  ✓ group_vars/all.yml"

    gum style --foreground 46 --bold \
      "\nConfiguration saved. Run 'just k3s::install' to provision the cluster."

# Provision the full cluster
install:
    @[[ -f {{INVENTORY}} ]] || just k3s::configure
    ansible-playbook -i {{INVENTORY}} {{PLAYBOOKS}}/install.yml

# Add a node interactively (server or worker)
add-node:
    ansible-playbook -i {{INVENTORY}} {{PLAYBOOKS}}/add-node.yml

# Tear down k3s from all nodes
teardown:
    ansible-playbook -i {{INVENTORY}} {{PLAYBOOKS}}/teardown.yml

# Show cluster node status
nodes:
    KUBECONFIG=$(yq '.kubeconfig_output' {{VARS_FILE}}) kubectl get nodes -o wide

# List all helm releases
helm-list:
    KUBECONFIG=$(yq '.kubeconfig_output' {{VARS_FILE}}) helm list -A

# Copy kubeconfig from control-plane node to ~/.kube/config
copy-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    init_node=$(yq '.all.children.control_plane.hosts | keys | .[0]' {{INVENTORY}})
    ssh_user=$(yq '.all.children.control_plane.hosts | to_entries | .[0].value.ansible_user' {{INVENTORY}})
    mkdir -p "$HOME/.kube"
    ssh -t "${ssh_user}@${init_node}" "sudo cat /etc/rancher/k3s/k3s.yaml" \
      | sed "s/127.0.0.1/${init_node}/g" \
      > "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"
    echo "kubeconfig written to ~/.kube/config"
