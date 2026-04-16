set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install External Secrets Operator + configure Vault ClusterSecretStore
# Depends on: vault (must be installed, unsealed, and configured)
#
# What this does:
#   1. Installs ESO via Helm in the external-secrets namespace
#   2. Creates a Vault Kubernetes auth role for the ESO service account
#   3. Applies a ClusterSecretStore pointing to in-cluster Vault (http://vault.vault.svc:8200)
#
# After this, apps can create ExternalSecret resources to pull from Vault KV-v2:
#   apiVersion: external-secrets.io/v1
#   kind: ExternalSecret
#   spec:
#     secretStoreRef:
#       name: vault
#       kind: ClusterSecretStore
#     data:
#       - secretKey: password
#         remoteRef:
#           key: secret/myapp/db
#           property: password
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing External Secrets Operator..."
    helm repo add external-secrets https://charts.external-secrets.io --force-update 2>/dev/null
    helm repo update external-secrets

    kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace external-secrets \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/warn=restricted --overwrite

    helm upgrade --install external-secrets external-secrets/external-secrets \
      --namespace external-secrets \
      --values "{{DIR}}/values.yaml" \
      --wait --timeout 5m

    gum style --foreground 46 "  ✓ ESO installed"

    # ── Wait for ESO CRDs and controller to be ready ─────────────────────
    gum style --bold --foreground 212 "Waiting for ESO CRDs..."
    kubectl wait --for=condition=Established \
      crd/clustersecretstores.external-secrets.io \
      crd/externalsecrets.external-secrets.io \
      --timeout=60s
    gum style --bold --foreground 212 "Waiting for ESO controller..."
    kubectl rollout status deployment/external-secrets \
      -n external-secrets --timeout=120s
    kubectl rollout status deployment/external-secrets-webhook \
      -n external-secrets --timeout=120s

    # ── Create Vault k8s auth role for ESO ───────────────────────────────
    gum style --bold --foreground 212 "Creating Vault auth role for ESO..."
    just eso::_create-vault-role

    # ── Apply ClusterSecretStore → Vault ─────────────────────────────────
    gum style --bold --foreground 212 "Applying ClusterSecretStore..."
    kubectl apply -f "{{DIR}}/cluster-secret-store.yaml"

    # Wait for ClusterSecretStore to become Ready
    gum style --bold --foreground 212 "Waiting for ClusterSecretStore to become Ready..."
    for i in $(seq 1 20); do
      STATUS=$(kubectl get clustersecretstore vault \
        -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null || echo "")
      if [ "$STATUS" = "True" ]; then
        gum style --foreground 46 "  ✓ ClusterSecretStore vault is Ready"
        break
      fi
      if [ "$i" -eq 20 ]; then
        gum style --foreground 196 "  ✗ ClusterSecretStore not ready after 60s — check: kubectl get clustersecretstore vault -o yaml"
        exit 1
      fi
      echo "  · waiting... (${i}/20)"
      sleep 3
    done

    gum style --foreground 46 "  ✓ ESO configured — apps can now use ClusterSecretStore 'vault'"
    gum style --foreground 244 "  · Secret path format: secret/data/<app>/<name>"
    gum style --foreground 244 "  · Write secrets: just vault::put secret/<app>/<name> key=value"

# Create the Vault Kubernetes auth role that allows the ESO service account to read secrets
# Called automatically by install — can also be run standalone to repair
_create-vault-role:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")

    # Delete first so existing fields (like stale audience) are fully replaced
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
      vault delete auth/kubernetes/role/external-secrets 2>/dev/null || true

    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
      vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets \
        bound_service_account_namespaces=external-secrets \
        policies=admin \
        ttl=1h

    gum style --foreground 46 "  ✓ Vault role 'external-secrets' created (policy: admin, ttl: 1h)"

# Show status of the ClusterSecretStore and all ExternalSecrets across all namespaces
status:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    echo "=== ClusterSecretStore ==="
    kubectl get clustersecretstore -o wide
    echo ""
    echo "=== ExternalSecrets (all namespaces) ==="
    kubectl get externalsecret -A

# Force-sync all ExternalSecrets in a namespace — just eso::sync myapp
sync namespace:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl annotate externalsecret -n "{{ namespace }}" --all \
      force-sync="$(date +%s)" --overwrite
    gum style --foreground 46 "  ✓ Triggered sync for all ExternalSecrets in {{ namespace }}"

# Uninstall ESO and remove ClusterSecretStore
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete clustersecretstore vault --ignore-not-found 2>/dev/null || true
    helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    kubectl delete namespace external-secrets --ignore-not-found
    gum style --foreground 46 "  ✓ ESO and ClusterSecretStore removed"
