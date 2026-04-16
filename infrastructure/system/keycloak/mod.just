set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"
SCRIPTS   := source_directory() / "scripts"

KC_HOST   := "keycloak.home.didcot"
KC_REALM  := "homelab"

# Install Keycloak via official image (quay.io/keycloak/keycloak)
# Depends on: postgres (create-user-db keycloak), vault, eso
#
# What this does:
#   1. Creates the keycloak PostgreSQL database (via postgres module)
#   2. Generates admin password → stores in Vault at secret/keycloak/admin
#   3. ESO ExternalSecrets sync admin + DB credentials into k8s Secrets
#   4. Deploys Keycloak via plain kubectl manifests (external PostgreSQL, proxy=xforwarded)
#   5. Applies HTTPRoute for keycloak.home.didcot
#   6. Creates the 'homelab' realm with sensible token lifespans
#   7. Creates an 'admins' group
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    # ── Preflight checks ──────────────────────────────────────────────────
    kubectl get crd clustersecretstores.external-secrets.io &>/dev/null || \
      { gum style --foreground 196 "ESO not installed — run: just eso::install"; exit 1; }
    kubectl get clusters.postgresql.cnpg.io postgres-cluster -n postgres &>/dev/null || \
      { gum style --foreground 196 "PostgreSQL not installed — run: just postgres::install"; exit 1; }

    # ── Bootstrap bun deps (first time only) ─────────────────────────────
    if [ ! -d "{{SCRIPTS}}/node_modules" ]; then
      gum style --bold --foreground 212 "Installing Keycloak script dependencies..."
      bun install --cwd "{{SCRIPTS}}" --silent
    fi

    # ── Create keycloak database in PostgreSQL ────────────────────────────
    gum style --bold --foreground 212 "Creating Keycloak database..."
    just postgres::create-user-db keycloak

    # ── Generate admin password → Vault ──────────────────────────────────
    gum style --bold --foreground 212 "Storing Keycloak admin credentials in Vault..."
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")

    VAULT_OUT=$(kubectl -n vault exec vault-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" vault kv get -format=json secret/keycloak/admin \
      2>/dev/null || true)
    EXISTING=$(echo "$VAULT_OUT" | jq -r ".data.data.password" 2>/dev/null || echo "")

    if [ -z "$EXISTING" ]; then
      KC_ADMIN_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
      kubectl -n vault exec vault-0 -- \
        env VAULT_TOKEN="$ROOT_TOKEN" \
        vault kv put secret/keycloak/admin \
          username=admin \
          password="$KC_ADMIN_PASS"
      gum style --foreground 46 "  ✓ Admin credentials written to Vault at secret/keycloak/admin"
    else
      KC_ADMIN_PASS="$EXISTING"
      gum style --foreground 244 "  · Admin credentials already in Vault — reusing"
    fi

    # ── Namespace + ESO ExternalSecrets ──────────────────────────────────
    kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace keycloak \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/warn=restricted --overwrite

    kubectl apply -f "{{DIR}}/admin-external-secret.yaml"
    kubectl apply -f "{{DIR}}/db-external-secret.yaml"

    gum style --bold --foreground 212 "Waiting for ExternalSecrets to sync..."
    kubectl wait --for=condition=Ready externalsecret/keycloak-admin -n keycloak --timeout=60s
    kubectl wait --for=condition=Ready externalsecret/keycloak-db    -n keycloak --timeout=60s
    gum style --foreground 46 "  ✓ Credentials synced into keycloak namespace"

    # ── Deploy Keycloak ───────────────────────────────────────────────────
    gum style --bold --foreground 212 "Deploying Keycloak..."
    kubectl apply -f "{{DIR}}/deployment.yaml"
    kubectl apply -f "{{DIR}}/service.yaml"
    kubectl apply -f "{{DIR}}/httproute.yaml"
    kubectl rollout status deployment/keycloak -n keycloak --timeout=5m
    gum style --foreground 46 "  ✓ Keycloak deployed"

    # ── Wait for Keycloak to be reachable ─────────────────────────────────
    gum style --bold --foreground 212 "Waiting for Keycloak to be reachable at https://{{KC_HOST}}..."
    for i in $(seq 1 30); do
      HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
        "https://{{KC_HOST}}/realms/master" 2>/dev/null || echo "000")
      if [ "$HTTP_CODE" = "200" ]; then
        gum style --foreground 46 "  ✓ Keycloak is reachable"
        break
      fi
      if [ "$i" -eq 30 ]; then
        gum style --foreground 196 "  ✗ Keycloak not reachable after 150s — check: kubectl get pods -n keycloak"
        exit 1
      fi
      echo "  · waiting... HTTP ${HTTP_CODE} (${i}/30)"
      sleep 5
    done

    # ── Create homelab realm + admins group ───────────────────────────────
    gum style --bold --foreground 212 "Creating '{{KC_REALM}}' realm..."
    just keycloak::create-realm "{{KC_REALM}}"

    gum style --bold --foreground 212 "Creating 'admins' group..."
    just keycloak::create-group "{{KC_REALM}}" "admins"

    gum style --foreground 46 "  ✓ Keycloak ready at https://{{KC_HOST}}"
    gum style --foreground 46 "  ✓ Realm '{{KC_REALM}}' created"
    gum style --foreground 212 "  · Admin UI: https://{{KC_HOST}}/admin"
    gum style --foreground 212 "  · Admin password: $KC_ADMIN_PASS"
    gum style --foreground 226 "  · Next: just keycloak::setup-vault-oidc"

# ── Admin helpers ──────────────────────────────────────────────────────────────

# Print the admin password (from k8s secret)
admin-password:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode
    echo

# ── Realm management ──────────────────────────────────────────────────────────

# Create a realm — just keycloak::create-realm homelab
create-realm realm:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
      bun "{{SCRIPTS}}/create-realm.ts"

# ── Client management ─────────────────────────────────────────────────────────

# Create an OIDC client
# just keycloak::create-client homelab grafana "https://grafana.home.didcot/*" [client-secret]
create-client realm client-id redirect-urls client-secret='':
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    KEYCLOAK_CLIENT_ID="{{ client-id }}" \
    KEYCLOAK_CLIENT_SECRET="{{ client-secret }}" \
    KEYCLOAK_REDIRECT_URL="{{ redirect-urls }}" \
      bun "{{SCRIPTS}}/create-client.ts"

# Delete a client — just keycloak::delete-client homelab grafana
delete-client realm client-id:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    KEYCLOAK_CLIENT_ID="{{ client-id }}" \
      bun "{{SCRIPTS}}/delete-client.ts"

# Get a client's secret — just keycloak::get-client-secret homelab vault
get-client-secret realm client-id:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    KEYCLOAK_CLIENT_ID="{{ client-id }}" \
      bun "{{SCRIPTS}}/get-client-secret.ts"

# Add audience mapper to a client (includes audience in JWT — required for most apps)
# just keycloak::add-audience-mapper homelab grafana grafana
add-audience-mapper realm client-id audience:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    KEYCLOAK_CLIENT_ID="{{ client-id }}" \
    KEYCLOAK_AUDIENCE="{{ audience }}" \
      bun "{{SCRIPTS}}/add-audience-mapper.ts"

# Add groups mapper to a client (includes group memberships in JWT)
# just keycloak::add-groups-mapper homelab grafana
add-groups-mapper realm client-id:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    KEYCLOAK_CLIENT_ID="{{ client-id }}" \
      bun "{{SCRIPTS}}/add-groups-mapper.ts"

# ── User management ───────────────────────────────────────────────────────────

# Create a user — just keycloak::create-user homelab john john@home.didcot
create-user realm username email password='':
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    USER_PASS="{{ password }}"
    if [ -z "$USER_PASS" ]; then
      USER_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 || true)
      echo "Generated password: $USER_PASS"
    fi
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    USERNAME="{{ username }}" \
    EMAIL="{{ email }}" \
    PASSWORD="$USER_PASS" \
      bun "{{SCRIPTS}}/create-user.ts"

# ── Group management ──────────────────────────────────────────────────────────

# Create a group — just keycloak::create-group homelab admins
create-group realm group:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    GROUP_NAME="{{ group }}" \
      bun "{{SCRIPTS}}/create-group.ts"

# Add a user to a group — just keycloak::add-user-to-group homelab john admins
add-user-to-group realm username group:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{ realm }}" \
    USERNAME="{{ username }}" \
    GROUP_NAME="{{ group }}" \
      bun "{{SCRIPTS}}/add-user-to-group.ts"

# ── OIDC wiring ───────────────────────────────────────────────────────────────

# Wire Vault OIDC to Keycloak
# Creates a Keycloak client for Vault, then configures Vault OIDC auth method
setup-vault-oidc:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")

    REDIRECT_URLS="https://vault.home.didcot/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback"

    gum style --bold --foreground 212 "Creating Vault OIDC client in Keycloak..."
    just keycloak::delete-client "{{KC_REALM}}" vault 2>/dev/null || true
    VAULT_CLIENT_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{KC_REALM}}" \
    KEYCLOAK_CLIENT_ID="vault" \
    KEYCLOAK_CLIENT_SECRET="$VAULT_CLIENT_SECRET" \
    KEYCLOAK_REDIRECT_URL="$REDIRECT_URLS" \
      bun "{{SCRIPTS}}/create-client.ts"

    just keycloak::add-audience-mapper "{{KC_REALM}}" vault vault
    just keycloak::add-groups-mapper   "{{KC_REALM}}" vault

    gum style --bold --foreground 212 "Configuring Vault OIDC auth method..."
    OIDC_DISCOVERY="https://{{KC_HOST}}/realms/{{KC_REALM}}"

    # Fetch homelab CA so Vault trusts the wildcard TLS cert on keycloak.home.didcot
    HOMELAB_CA=$(kubectl get secret homelab-ca-secret -n cert-manager \
      -o jsonpath="{.data.tls\.crt}" | base64 -d)

    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
      vault auth enable oidc 2>/dev/null || true

    kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
      vault write auth/oidc/config \
        oidc_discovery_url="$OIDC_DISCOVERY" \
        oidc_client_id="vault" \
        oidc_client_secret="$VAULT_CLIENT_SECRET" \
        oidc_discovery_ca_pem="$HOMELAB_CA" \
        default_role="default"

    kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
      vault write auth/oidc/role/default \
        bound_audiences="vault" \
        "allowed_redirect_uris=https://vault.home.didcot/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
        user_claim="preferred_username" \
        groups_claim="groups" \
        token_policies="default-read" \
        ttl="12h"

    printf '{"bound_audiences":"vault","allowed_redirect_uris":["https://vault.home.didcot/ui/vault/auth/oidc/oidc/callback","http://localhost:8250/oidc/callback"],"bound_claims_type":"glob","bound_claims":{"groups":["admins"]},"user_claim":"preferred_username","groups_claim":"groups","token_policies":"admin","ttl":"12h"}' \
      | kubectl -n vault exec -i vault-0 -- \
          sh -c "cat > /tmp/admin-role.json && env VAULT_TOKEN=\"$ROOT_TOKEN\" vault write auth/oidc/role/admin @/tmp/admin-role.json"

    gum style --foreground 46 "  ✓ Vault OIDC configured"
    gum style --foreground 46 "  ✓ Login: vault login -method=oidc -address=https://vault.home.didcot"
    gum style --foreground 226 "  · Add a user to 'admins' group for admin Vault access"
    gum style --foreground 226 "  · Next: just keycloak::setup-k8s-oidc"

# Configure k3s to use Keycloak as OIDC provider for kubectl
# After this: kubelogin + kubectl will authenticate via Keycloak SSO
setup-k8s-oidc:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    KC_PASS=$(kubectl get secret keycloak-admin -n keycloak \
      -o jsonpath="{.data.password}" | base64 --decode)

    REDIRECT_URLS="http://localhost:8000,http://localhost:18000"
    K8S_CLIENT_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)

    gum style --bold --foreground 212 "Creating k8s OIDC client in Keycloak..."
    just keycloak::delete-client "{{KC_REALM}}" kubernetes 2>/dev/null || true
    KEYCLOAK_HOST="{{KC_HOST}}" \
    KEYCLOAK_ADMIN_USER="admin" \
    KEYCLOAK_ADMIN_PASSWORD="$KC_PASS" \
    KEYCLOAK_REALM="{{KC_REALM}}" \
    KEYCLOAK_CLIENT_ID="kubernetes" \
    KEYCLOAK_CLIENT_SECRET="$K8S_CLIENT_SECRET" \
    KEYCLOAK_REDIRECT_URL="$REDIRECT_URLS" \
      bun "{{SCRIPTS}}/create-client.ts"

    just keycloak::add-audience-mapper "{{KC_REALM}}" kubernetes kubernetes
    just keycloak::add-groups-mapper   "{{KC_REALM}}" kubernetes

    OIDC_ISSUER="https://{{KC_HOST}}/realms/{{KC_REALM}}"

    gum style --bold --foreground 212 "Configuring k3s OIDC flags..."
    # Write OIDC config to k3s server config on each control-plane node
    ansible-playbook -i "{{METAL_DIR}}/inventory.yml" \
      "{{DIR}}/setup-oidc.yml" \
      -e "oidc_issuer_url=${OIDC_ISSUER}" \
      -e "oidc_client_id=kubernetes" \
      -e "oidc_groups_claim=groups"

    gum style --bold --foreground 212 "Applying OIDC RBAC bindings..."
    kubectl apply -f "{{DIR}}/k8s-rbac.yaml"

    gum style --foreground 46 "  ✓ k3s OIDC configured (k3s restarted on control-plane nodes)"
    gum style --foreground 46 "  ✓ Issuer: $OIDC_ISSUER"
    gum style --foreground 46 "  ✓ RBAC: group 'oidc:admins' → cluster-admin"
    gum style --foreground 212 "  · Store the client secret, then configure kubelogin:"
    gum style --foreground 212 "      kubectl oidc-login setup \\"
    gum style --foreground 212 "        --oidc-issuer-url=$OIDC_ISSUER \\"
    gum style --foreground 212 "        --oidc-client-id=kubernetes \\"
    gum style --foreground 212 "        --oidc-client-secret=$K8S_CLIENT_SECRET"

# ── Uninstall ─────────────────────────────────────────────────────────────────

# Uninstall Keycloak — removes all data
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl delete -f "{{DIR}}/httproute.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/admin-external-secret.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/db-external-secret.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/deployment.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "{{DIR}}/service.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace keycloak --ignore-not-found
    gum style --foreground 46 "  ✓ Keycloak removed"
    gum style --foreground 244 "  · Database 'keycloak' in PostgreSQL was NOT deleted"
    gum style --foreground 244 "  · To remove: just postgres::delete-user-db keycloak"
