set shell := ["bash", "-euo", "pipefail", "-c"]

DIR      := source_directory()
METAL_DIR := source_directory() / ".." / ".." / ".." / "infrastructure" / "metal"

# Install Tandoor (recipe manager + shopping list)
# Depends on: postgres, vault, eso, gateway
#
# What this does:
#   1. Creates 'tandoor' database in CNPG (just postgres::create-user-db)
#   2. Generates a SECRET_KEY → stores in Vault at secret/tandoor/config
#   3. ESO ExternalSecret syncs DB password + SECRET_KEY into tandoor-secret
#   4. Deploys Tandoor (nginx sidecar, gunicorn, init migrations)
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    # ── Create tandoor database in CNPG ──────────────────────────────────
    gum style --bold --foreground 212 "Creating Tandoor database..."
    just postgres::create-user-db tandoor

    # ── Generate SECRET_KEY → Vault ───────────────────────────────────────
    gum style --bold --foreground 212 "Storing Tandoor config in Vault..."
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")

    VAULT_OUT=$(kubectl -n vault exec vault-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" vault kv get -format=json secret/tandoor/config \
      2>/dev/null || true)
    EXISTING=$(echo "$VAULT_OUT" | jq -r ".data.data.secret_key" 2>/dev/null || echo "")

    if [ -z "$EXISTING" ]; then
      SECRET_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 50 || true)
      kubectl -n vault exec vault-0 -- \
        env VAULT_TOKEN="$ROOT_TOKEN" \
        vault kv put secret/tandoor/config \
          secret_key="$SECRET_KEY"
      gum style --foreground 46 "  ✓ SECRET_KEY written to Vault at secret/tandoor/config"
    else
      gum style --foreground 244 "  · SECRET_KEY already in Vault — skipping"
    fi

    # ── Apply manifests ───────────────────────────────────────────────────
    gum style --bold --foreground 212 "Installing Tandoor..."

    kubectl apply -f "{{DIR}}/namespace.yaml"
    kubectl apply -f "{{DIR}}/external-secret.yaml"

    gum style --bold --foreground 212 "Waiting for ExternalSecret to sync..."
    kubectl wait --for=condition=Ready externalsecret/tandoor-secret \
      -n tandoor --timeout=60s
    gum style --foreground 46 "  ✓ Credentials synced into tandoor namespace"

    kubectl apply -f "{{DIR}}/configmap.yaml"
    kubectl apply -f "{{DIR}}/pvc.yaml"
    kubectl apply -f "{{DIR}}/deployment.yaml"
    kubectl apply -f "{{DIR}}/service.yaml"
    kubectl apply -f "{{DIR}}/httproute.yaml"

    gum style --bold --foreground 212 "Waiting for Tandoor (includes migrations + static files)..."
    kubectl -n tandoor rollout status deployment/recipes --timeout=600s

    gum style --foreground 46 "  ✓ Tandoor running at https://tandoor.home.didcot"
    gum style --foreground 212 "  · Create your account at https://tandoor.home.didcot/accounts/register"

# Uninstall Tandoor — removes all k8s resources (DB is preserved)
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{DIR}}/httproute.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/service.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/deployment.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/pvc.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/configmap.yaml" --ignore-not-found
    kubectl delete -f "{{DIR}}/external-secret.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/namespace.yaml" --ignore-not-found
    gum style --foreground 46 "  ✓ Tandoor removed"
    gum style --foreground 244 "  · Database 'tandoor' in PostgreSQL was NOT deleted"
    gum style --foreground 244 "  · To remove: just postgres::delete-user-db tandoor"
