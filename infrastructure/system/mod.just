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
install: cilium longhorn adguard homepage skypilot
    @gum style --foreground 46 --bold "\nAll system components ready."

# Remove all system components
uninstall: skypilot-uninstall homepage-uninstall adguard-uninstall longhorn-uninstall cilium-uninstall


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

# Install SkyPilot API server + dashboard
skypilot:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing SkyPilot API server..."

    helm repo add skypilot https://skypilot-org.github.io/skypilot-helm --force-update 2>/dev/null
    helm repo update skypilot

    helm upgrade --install skypilot skypilot/skypilot \
      --namespace skypilot \
      --create-namespace \
      --version 0.12.0 \
      --values "{{SYSTEM_DIR}}/skypilot/values.yaml" \
      --wait --timeout 5m

    gum style --foreground 46 "  ✓ SkyPilot running at http://192.168.0.8"
    gum style --foreground 46 "  ✓ Configure CLI: sky api login http://192.168.0.8"

# Uninstall SkyPilot
skypilot-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum confirm "Remove SkyPilot and all job data?" || exit 0

    helm uninstall skypilot -n skypilot --wait 2>/dev/null || true
    kubectl delete namespace skypilot --ignore-not-found
    gum style --foreground 46 "  ✓ SkyPilot removed"

# Install Homepage dashboard
homepage:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing metrics-server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

    gum style --bold --foreground 212 "Installing Homepage..."

    kubectl apply -f "{{SYSTEM_DIR}}/homepage/namespace.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/homepage/rbac.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/homepage/configmap.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/homepage/deployment.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/homepage/service.yaml"

    kubectl -n homepage rollout status deployment/homepage --timeout=120s

    gum style --foreground 46 "  ✓ Homepage running at http://192.168.0.7"

# Uninstall Homepage
homepage-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{SYSTEM_DIR}}/homepage/" --ignore-not-found
    gum style --foreground 46 "  ✓ Homepage removed"

# Install Longhorn (replicated distributed storage)
longhorn:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing Longhorn prerequisites on nodes..."
    ansible-playbook -i "{{METAL_DIR}}/inventory.yml" \
      "{{SYSTEM_DIR}}/longhorn/prerequisites.yml"

    gum style --bold --foreground 212 "Installing Longhorn..."
    helm repo add longhorn https://charts.longhorn.io --force-update 2>/dev/null
    helm repo update longhorn

    helm upgrade --install longhorn longhorn/longhorn \
      --namespace longhorn-system \
      --create-namespace \
      --version 1.7.2 \
      --values "{{SYSTEM_DIR}}/longhorn/values.yaml" \
      --wait --timeout 10m

    gum style --foreground 46 "  ✓ Longhorn installed (2 replicas, default StorageClass)"

# Uninstall Longhorn
longhorn-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum confirm "Remove Longhorn and ALL volume data?" || exit 0

    helm uninstall longhorn -n longhorn-system --wait
    kubectl delete namespace longhorn-system --ignore-not-found
    gum style --foreground 46 "  ✓ Longhorn uninstalled"

# Install AdGuard Home (DNS + ad blocking) at 192.168.0.3
adguard:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing AdGuard Home..."

    kubectl apply -f "{{SYSTEM_DIR}}/adguard/namespace.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/adguard/pvc.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/adguard/deployment.yaml"
    kubectl apply -f "{{SYSTEM_DIR}}/adguard/service.yaml"

    kubectl -n adguard rollout status deployment/adguard-home --timeout=120s

    gum style --foreground 46 "  ✓ AdGuard Home running"
    gum style --foreground 46 "  ✓ DNS:      192.168.0.3:53"
    gum style --foreground 46 "  ✓ Setup UI: http://192.168.0.3:3000"

# Uninstall AdGuard Home
adguard-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq '.kubeconfig_output' "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum confirm "Remove AdGuard Home and all data?" || exit 0

    kubectl delete -f "{{SYSTEM_DIR}}/adguard/" --ignore-not-found
    gum style --foreground 46 "  ✓ AdGuard Home removed"

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
