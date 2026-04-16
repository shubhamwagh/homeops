set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install SkyPilot API server + dashboard
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    # Remove stale nginx admission webhook — its cert becomes invalid after reinstall
    kubectl delete validatingwebhookconfiguration skypilot-ingress-nginx-admission --ignore-not-found 2>/dev/null || true

    gum style --bold --foreground 212 "Installing SkyPilot API server..."
    helm repo add skypilot https://skypilot-org.github.io/skypilot-helm --force-update 2>/dev/null
    helm repo update skypilot

    helm upgrade --install skypilot skypilot/skypilot \
      --namespace skypilot \
      --create-namespace \
      --version 0.12.0 \
      --values "{{DIR}}/values.yaml" \
      --wait --timeout 10m

    kubectl apply -f "{{DIR}}/httproute.yaml"

    gum style --foreground 46 "  ✓ SkyPilot running at https://skypilot.home.didcot"
    gum style --foreground 46 "  ✓ Configure CLI: sky api login -e https://skypilot.home.didcot"

# Uninstall SkyPilot
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{DIR}}/httproute.yaml" --ignore-not-found 2>/dev/null || true
    helm uninstall skypilot -n skypilot --wait 2>/dev/null || true
    kubectl delete pvc --all -n skypilot --ignore-not-found
    kubectl delete namespace skypilot --ignore-not-found
    gum style --foreground 46 "  ✓ SkyPilot removed"
