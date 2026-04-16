set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install Vault (single replica, Raft on Longhorn) following buun-stack pattern:
#   - dedicated vault-auth ServiceAccount for k8s auth reviewer
#   - key-shares=1, key-threshold=1 (homelab single replica)
#   - unseal key stored in vault/vault-unseal-keys k8s secret
#   - KV-v2 + Kubernetes auth + admin policy configured post-install
# First run: initialises and unseals. Subsequent runs: idempotent.
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing Vault..."
    helm repo add hashicorp https://helm.releases.hashicorp.com --force-update 2>/dev/null
    helm repo update hashicorp

    kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace vault pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/warn=restricted --overwrite

    kubectl apply -f "{{DIR}}/vault-auth-sa.yaml"

    helm upgrade --install vault hashicorp/vault \
      --namespace vault \
      --values "{{DIR}}/values.yaml" \
      --wait --timeout 5m

    gum style --bold --foreground 212 "Waiting for Vault pod..."
    kubectl -n vault wait pod/vault-0 --for=condition=Ready --timeout=120s 2>/dev/null || true

    # ── Initialise (only on first install) ───────────────────────────────
    VAULT_STATUS=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null || true)
    INITIALIZED=$(echo "$VAULT_STATUS" | jq -r ".initialized" 2>/dev/null || echo "false")

    if [ "$INITIALIZED" = "false" ]; then
      gum style --bold --foreground 212 "Initialising Vault (first time)..."

      kubectl -n vault exec vault-0 -- \
        vault operator init -key-shares=1 -key-threshold=1 -format=json \
        > /tmp/vault-init.json

      kubectl -n vault create secret generic vault-unseal-keys \
        --from-file=init.json=/tmp/vault-init.json \
        --dry-run=client -o yaml | kubectl apply -f -
      rm /tmp/vault-init.json

      gum style --foreground 226 "  · Unseal key stored in secret vault/vault-unseal-keys"
    fi

    # ── Unseal vault-0 ────────────────────────────────────────────────────
    just vault::unseal

    # ── Configure Vault (KV-v2, Kubernetes auth, admin + default-read policies) ──
    gum style --bold --foreground 212 "Configuring Vault..."
    bash "{{DIR}}/configure.sh"

    kubectl apply -f "{{DIR}}/httproute.yaml"

    DISPLAY_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    gum style --foreground 46 "  ✓ Vault running at https://vault.home.didcot"
    gum style --foreground 212 "  · Root token: $DISPLAY_TOKEN"
    gum style --foreground 226 "  · Run: just vault::unseal   (after every cluster restart)"

# Unseal vault-0
# Reads unseal key from vault/vault-unseal-keys k8s secret by default.
# Set VAULT_UNSEAL_KEY=op://vault/unseal/key to use 1Password instead.
unseal:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Unsealing Vault..."

    if [ -n "${VAULT_UNSEAL_KEY:-}" ]; then
      # 1Password or env-var override
      if [[ "${VAULT_UNSEAL_KEY}" == op://* ]]; then
        command -v op &>/dev/null || { echo "Error: 1Password CLI (op) not installed"; exit 1; }
        UNSEAL_KEY=$(op read "${VAULT_UNSEAL_KEY}")
      else
        UNSEAL_KEY="${VAULT_UNSEAL_KEY}"
      fi
    else
      INIT_JSON=$(kubectl -n vault get secret vault-unseal-keys -o json \
        | jq -r ".data[\"init.json\"]" | base64 -d)
      UNSEAL_KEY=$(echo "$INIT_JSON" | jq -r ".unseal_keys_b64[0]")
    fi

    VAULT_STATUS=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null || true)
    SEALED=$(echo "$VAULT_STATUS" | jq -r ".sealed" 2>/dev/null || echo "true")

    if [ "$SEALED" = "true" ]; then
      kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL_KEY" > /dev/null
      gum style --foreground 46 "  ✓ vault-0 unsealed"
    else
      gum style --foreground 244 "  · vault-0 already unsealed"
    fi

# Print the root token (for initial UI login)
token:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token"

# Show Vault status
status:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl -n vault exec vault-0 -- vault status || true

# Read a KV-v2 secret — just vault::get secret/myapp/db
get path:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault kv get "{{ path }}"

# Write a KV-v2 secret — just vault::put secret/myapp/db password=foo api_key=bar
put path +args:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault kv put "{{ path }}" {{ args }}

# Delete a KV-v2 secret — just vault::delete secret/myapp/db
delete path:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault kv delete "{{ path }}"

# List all secrets at a path — just vault::list secret/myapp
list path:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault kv list "{{ path }}"

# Write a Vault policy from a .hcl file — just vault::write-policy myapp ./myapp.hcl
write-policy name file:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    kubectl cp "{{ file }}" vault/vault-0:/tmp/policy.hcl
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault policy write "{{ name }}" /tmp/policy.hcl
    kubectl -n vault exec vault-0 -- rm /tmp/policy.hcl

# Create a Kubernetes auth role for a service account
# just vault::create-role myapp myapp-sa myapp-namespace secret/data/myapp/*
create-role role sa namespace policy:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
      vault write auth/kubernetes/role/{{ role }} \
        bound_service_account_names={{ sa }} \
        bound_service_account_namespaces={{ namespace }} \
        policies={{ policy }} \
        ttl=1h
    gum style --foreground 46 "  ✓ Vault k8s auth role '{{ role }}' created"

# Uninstall Vault — removes all data and the vault namespace
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{DIR}}/httproute.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/vault-auth-sa.yaml" --ignore-not-found
    helm uninstall vault -n vault 2>/dev/null || true
    kubectl delete pvc -n vault --all --ignore-not-found
    kubectl delete secret vault-unseal-keys -n vault --ignore-not-found
    kubectl delete namespace vault --ignore-not-found
    gum style --foreground 46 "  ✓ Vault removed"
