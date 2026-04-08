# =============================================================
# system/mod.just — cluster-level infrastructure
#
# Installs foundational components that must be present before
# any workloads can run. Run once after `just metal::install`.
#
# Usage:
#   just system::install   — install all system components
#   just system::cilium    — install / upgrade Cilium only
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

SYSTEM_DIR := justfile_directory() / "infrastructure" / "system"
METAL_DIR  := justfile_directory() / "infrastructure" / "metal"

# Install all system components (idempotent)
install: cilium

# Remove all system components
uninstall: cilium-uninstall
    @gum style --foreground 46 --bold "\nSystem components ready."

# Install / upgrade Cilium (CNI + kube-proxy replacement + L2 load balancer)
cilium:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing Cilium..."

    [[ -f "{{METAL_DIR}}/group_vars/all.yml" ]] || \
      { gum style --foreground 196 "Run 'just metal::configure' first"; exit 1; }

    # Derive control-plane endpoint: VIP if HA, else first CP node IP
    CP_VIP=$(yq '.control_plane_vip' "{{METAL_DIR}}/group_vars/all.yml")
    FIRST_CP=$(yq '.all.children.control_plane.hosts | keys | .[0]' "{{METAL_DIR}}/inventory.yml")
    CP_HOST=${CP_VIP:-$FIRST_CP}
    gum style --foreground 244 "  · control-plane endpoint: ${CP_HOST}"

    helm repo add cilium https://helm.cilium.io/ --force-update 2>/dev/null
    helm repo update cilium

    helm upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version 1.17.3 \
      --values "{{SYSTEM_DIR}}/cilium/values.yaml" \
      --set k8sServiceHost="${CP_HOST}" \
      --wait

    gum style --foreground 46 "  ✓ Cilium installed"

    gum style --bold --foreground 212 "Applying L2 announcement policy and IP pool..."
    kubectl apply -f "{{SYSTEM_DIR}}/cilium/ip-pool.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/cilium/l2-policy.yaml"

    gum style --foreground 46 "  ✓ IP pool: 192.168.0.2 – 192.168.0.14"
    gum style --foreground 46 "  ✓ L2 announcement policy applied"

    kubectl -n kube-system rollout status daemonset/cilium --timeout=120s

# Uninstall Cilium and remove L2 policy + IP pool
cilium-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum confirm "Remove Cilium and all L2/IP pool config?" || exit 0

    kubectl delete -f "{{SYSTEM_DIR}}/cilium/l2-policy.yaml" --ignore-not-found
    kubectl delete -f "{{SYSTEM_DIR}}/cilium/ip-pool.yaml" --ignore-not-found
    gum style --foreground 46 "  ✓ L2 policy and IP pool removed"

    helm uninstall cilium -n kube-system --wait
    gum style --foreground 46 "  ✓ Cilium uninstalled"
