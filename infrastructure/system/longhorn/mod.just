set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install Longhorn (replicated distributed storage)
# Prerequisite: runs Ansible playbook to configure iSCSI + multipath on all nodes
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing Longhorn prerequisites on nodes..."
    ansible-playbook -i "{{METAL_DIR}}/inventory.yml" \
      "{{DIR}}/prerequisites.yml"

    gum style --bold --foreground 212 "Installing Longhorn..."
    helm repo add longhorn https://charts.longhorn.io --force-update 2>/dev/null
    helm repo update longhorn

    helm upgrade --install longhorn longhorn/longhorn \
      --namespace longhorn-system \
      --create-namespace \
      --version 1.7.2 \
      --values "{{DIR}}/values.yaml" \
      --wait --timeout 10m

    # longhorn-driver-deployer creates csi-provisioner dynamically — poll until it appears
    gum style --bold --foreground 212 "Waiting for Longhorn driver deployer..."
    kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=3m
    gum style --bold --foreground 212 "Waiting for Longhorn CSI deployments..."
    for i in $(seq 1 30); do
      kubectl get deploy csi-provisioner -n longhorn-system &>/dev/null && break
      echo "  · not ready yet, retrying in 5s... (${i}/30)"
      sleep 5
    done
    kubectl -n longhorn-system rollout status deploy/csi-provisioner --timeout=3m

    gum style --bold --foreground 212 "Waiting for Longhorn CSI plugin (nodes)..."
    kubectl -n longhorn-system rollout status ds/longhorn-csi-plugin --timeout=3m

    gum style --foreground 46 "  ✓ Longhorn installed (2 replicas, default StorageClass)"

# Uninstall Longhorn — deletes all PVCs, CRDs, and namespace
# WARNING: all persistent data on Longhorn volumes will be lost
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Deleting all Longhorn PVCs..."
    kubectl get pvc -A -o json | \
      jq -r ".items[] | select(.spec.storageClassName==\"longhorn\") | \"\(.metadata.namespace) \(.metadata.name)\"" | \
      while read ns name; do kubectl delete pvc "$name" -n "$ns" --ignore-not-found; done

    kubectl -n longhorn-system patch lhs deleting-confirmation-flag \
      -p '{"value": "true"}' --type=merge 2>/dev/null || true

    gum style --bold --foreground 212 "Uninstalling Longhorn (this may take a few minutes)..."
    helm uninstall longhorn -n longhorn-system --wait --timeout 10m 2>/dev/null || true

    kubectl get crd -o name | grep longhorn | xargs --no-run-if-empty kubectl delete --ignore-not-found 2>/dev/null || true
    kubectl delete namespace longhorn-system --ignore-not-found

    gum style --foreground 46 "  ✓ Longhorn uninstalled and PVs removed"
    gum style --foreground 244 "  · Node disk data in /var/lib/longhorn is cleaned by Longhorn's uninstall job"
