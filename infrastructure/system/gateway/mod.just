set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install Gateway API CRDs + Cilium Gateway + wildcard TLS cert + HTTPRoutes
# Depends on: cilium, cert-manager
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing Gateway API CRDs (experimental)..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml

    # Cilium must be upgraded after Gateway API CRDs exist so it can register the GatewayClass
    gum style --bold --foreground 212 "Upgrading Cilium to register GatewayClass..."
    CP_VIP=$(yq ".control_plane_vip" "{{METAL_DIR}}/group_vars/all.yml")
    FIRST_CP=$(yq ".all.children.control_plane.hosts | keys | .[0]" "{{METAL_DIR}}/inventory.yml")
    CP_HOST=${CP_VIP:-$FIRST_CP}
    helm upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version 1.17.3 \
      --values "{{DIR}}/../cilium/values.yaml" \
      --set k8sServiceHost="${CP_HOST}" \
      --wait

    gum style --bold --foreground 212 "Waiting for Cilium operator to register GatewayClass..."
    kubectl rollout restart deployment/cilium-operator -n kube-system
    kubectl rollout status deployment/cilium-operator -n kube-system --timeout=60s
    sleep 5

    gum style --bold --foreground 212 "Applying Gateway resources..."
    kubectl apply -f "{{DIR}}/certificate.yaml"
    kubectl wait certificate wildcard-home-didcot -n kube-system --for=condition=Ready --timeout=60s

    kubectl apply -f "{{DIR}}/gateway.yaml"
    kubectl apply -f "{{DIR}}/routes.yaml"

    just gateway::patch-coredns

    gum style --foreground 46 "  ✓ Wildcard cert issued (*.home.didcot)"
    gum style --foreground 46 "  ✓ Gateway running at 192.168.0.9"
    gum style --foreground 46 "  ✓ CoreDNS patched — *.home.didcot resolves inside cluster"
    gum style --foreground 46 "  ✓ HTTPS routes: adguard / longhorn / hubble / homepage / skypilot / vault"
    gum style --foreground 212 --bold "  · Add DNS rewrite in AdGuard: *.home.didcot → 192.168.0.9"

# Patch CoreDNS to forward home.didcot queries to AdGuard
# Allows pods inside the cluster to resolve *.home.didcot hostnames
# Run once after gateway install
patch-coredns:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    # k3s CoreDNS auto-reloads coredns-custom ConfigMap — no restart needed
    kubectl apply -f "{{DIR}}/coredns-patch.yaml"
    sleep 5
    gum style --foreground 46 "  ✓ CoreDNS patched — *.home.didcot resolves inside cluster"

# Uninstall Gateway API resources and CRDs
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    if kubectl get crd httproutes.gateway.networking.k8s.io &>/dev/null; then
      kubectl delete httproute http-redirect -n kube-system --ignore-not-found
      kubectl delete httproute adguard       -n adguard      --ignore-not-found
      kubectl delete httproute longhorn      -n longhorn-system --ignore-not-found
      kubectl delete httproute hubble        -n kube-system  --ignore-not-found
      kubectl delete httproute homepage      -n homepage     --ignore-not-found
      kubectl delete httproute skypilot      -n skypilot     --ignore-not-found
    fi

    if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
      kubectl delete gateway homelab -n kube-system --ignore-not-found
    fi

    if kubectl get crd certificates.cert-manager.io &>/dev/null; then
      kubectl delete certificate wildcard-home-didcot -n kube-system --ignore-not-found
    fi

    kubectl delete secret wildcard-home-didcot -n kube-system --ignore-not-found
    kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml --ignore-not-found 2>/dev/null || true

    gum style --foreground 46 "  ✓ Gateway resources and CRDs removed"
