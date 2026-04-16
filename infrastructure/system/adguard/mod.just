set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install AdGuard Home (DNS + ad blocking)
# After install: open http://192.168.0.3:3000 to complete setup wizard
# Then add DNS rewrite: *.home.didcot → 192.168.0.9
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing AdGuard Home..."

    kubectl apply -f "{{DIR}}/namespace.yaml"
    kubectl apply -f "{{DIR}}/pvc.yaml"
    kubectl apply -f "{{DIR}}/deployment.yaml"
    kubectl apply -f "{{DIR}}/service.yaml"

    gum style --bold --foreground 212 "Waiting for AdGuard Home to start..."
    kubectl -n adguard rollout status deployment/adguard-home --timeout=300s

    gum style --foreground 46 "  ✓ AdGuard Home running"
    gum style --foreground 46 "  ✓ DNS:      192.168.0.3:53"
    gum style --foreground 46 "  ✓ Setup UI: http://192.168.0.3:3000"
    gum style --foreground 212 "  · Complete setup wizard, then add DNS rewrite: *.home.didcot → 192.168.0.9"

# Uninstall AdGuard Home
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{DIR}}/service.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/deployment.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/pvc.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/namespace.yaml" --ignore-not-found
    gum style --foreground 46 "  ✓ AdGuard Home removed"
