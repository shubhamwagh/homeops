set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install / upgrade Cilium (CNI + kube-proxy replacement + L2 load balancer)
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing Cilium..."

    [[ -f "{{METAL_DIR}}/group_vars/all.yml" ]] || \
      { gum style --foreground 196 "Run 'just metal::configure' first"; exit 1; }

    # Derive control-plane endpoint: VIP if HA, else first CP node IP
    CP_VIP=$(yq ".control_plane_vip" "{{METAL_DIR}}/group_vars/all.yml")
    FIRST_CP=$(yq ".all.children.control_plane.hosts | keys | .[0]" "{{METAL_DIR}}/inventory.yml")
    CP_HOST=${CP_VIP:-$FIRST_CP}
    gum style --foreground 244 "  · control-plane endpoint: ${CP_HOST}"

    # Gateway API CRDs must exist before Cilium (gatewayAPI.enabled: true in values)
    gum style --bold --foreground 212 "Installing Gateway API CRDs..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml

    # Flush stale iptables chains from any previous Cilium installation
    for pod in $(kubectl get pods -n kube-system -l k8s-app=cilium -o name 2>/dev/null || true); do
      kubectl exec -n kube-system "$pod" -c cilium-agent -- sh -c "
        for chain in OLD_CILIUM_PRE_nat OLD_CILIUM_POST_nat OLD_CILIUM_OUTPUT_nat \
                     OLD_CILIUM_PRE_mangle OLD_CILIUM_POST_mangle OLD_CILIUM_OUTPUT_mangle; do
          iptables -t nat -F \$chain 2>/dev/null && iptables -t nat -X \$chain 2>/dev/null || true
          iptables -t mangle -F \$chain 2>/dev/null && iptables -t mangle -X \$chain 2>/dev/null || true
        done
      " 2>/dev/null || true
    done

    helm repo add cilium https://helm.cilium.io/ --force-update 2>/dev/null
    helm repo update cilium

    helm upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version 1.17.3 \
      --values "{{DIR}}/values.yaml" \
      --set k8sServiceHost="${CP_HOST}" \
      --wait

    gum style --foreground 46 "  ✓ Cilium installed"

    gum style --bold --foreground 212 "Applying L2 announcement policy and IP pool..."
    kubectl apply -f "{{DIR}}/ip-pool.yaml"
    kubectl apply -f "{{DIR}}/l2-policy.yaml"

    gum style --foreground 46 "  ✓ IP pool: 192.168.0.2 – 192.168.0.14"
    gum style --foreground 46 "  ✓ L2 announcement policy applied"

    gum style --bold --foreground 212 "Waiting for Cilium DaemonSet to be ready..."
    kubectl -n kube-system rollout status daemonset/cilium --timeout=120s

# Uninstall Cilium (WARNING: removes cluster CNI — do this only before full teardown)
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    if kubectl get crd ciliuml2announcementpolicies.cilium.io &>/dev/null; then
      kubectl delete -f "{{DIR}}/l2-policy.yaml" --ignore-not-found
    fi
    if kubectl get crd ciliumloadbalancerippools.cilium.io &>/dev/null; then
      kubectl delete -f "{{DIR}}/ip-pool.yaml" --ignore-not-found
    fi
    gum style --foreground 46 "  ✓ L2 policy and IP pool removed"

    gum style --bold --foreground 212 "Cleaning up iptables chains..."
    for pod in $(kubectl get pods -n kube-system -l k8s-app=cilium -o name 2>/dev/null || true); do
      kubectl exec -n kube-system "$pod" -c cilium-agent -- sh -c "
        for chain in OLD_CILIUM_PRE_nat OLD_CILIUM_POST_nat OLD_CILIUM_OUTPUT_nat \
                     CILIUM_PRE_nat CILIUM_POST_nat CILIUM_OUTPUT_nat \
                     OLD_CILIUM_PRE_mangle OLD_CILIUM_POST_mangle OLD_CILIUM_OUTPUT_mangle \
                     CILIUM_PRE_mangle CILIUM_POST_mangle CILIUM_OUTPUT_mangle; do
          iptables -t nat -F \$chain 2>/dev/null && iptables -t nat -X \$chain 2>/dev/null || true
          iptables -t mangle -F \$chain 2>/dev/null && iptables -t mangle -X \$chain 2>/dev/null || true
        done
      " 2>/dev/null || true
    done

    helm uninstall cilium -n kube-system --wait 2>/dev/null || true
    kubectl get crd -o name | grep cilium | xargs --no-run-if-empty kubectl delete --ignore-not-found 2>/dev/null || true
    gum style --foreground 46 "  ✓ Cilium uninstalled"
