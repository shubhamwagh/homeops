set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install Homepage dashboard + metrics-server
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing metrics-server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

    gum style --bold --foreground 212 "Installing Homepage..."
    kubectl apply -f "{{DIR}}/namespace.yaml"
    kubectl apply -f "{{DIR}}/rbac.yaml"
    kubectl apply -f "{{DIR}}/configmap.yaml"
    kubectl apply -f "{{DIR}}/deployment.yaml"
    kubectl apply -f "{{DIR}}/service.yaml"
    kubectl apply -f "{{DIR}}/httproute.yaml"

    gum style --bold --foreground 212 "Waiting for Homepage to start..."
    kubectl -n homepage rollout status deployment/homepage --timeout=120s

    gum style --foreground 46 "  ✓ Homepage running at https://homepage.home.didcot"

# Uninstall Homepage and metrics-server
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{DIR}}/httproute.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/service.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/deployment.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/configmap.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/rbac.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/namespace.yaml" --ignore-not-found
    kubectl delete deployment metrics-server -n kube-system --ignore-not-found
    kubectl delete service metrics-server -n kube-system --ignore-not-found
    kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found
    gum style --foreground 46 "  ✓ Homepage and metrics-server removed"
