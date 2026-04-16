set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

CNPG_NS := "postgres"

# Install CloudNativePG operator + create postgres-cluster
# Depends on: longhorn (storage), vault (secrets), eso (ExternalSecret sync)
#
# What this does:
#   1. Installs CNPG operator via Helm
#   2. Generates a random admin password → stores it in Vault at secret/postgres/admin
#   3. ESO ExternalSecret syncs the password into a k8s Secret for the cluster
#   4. Creates the postgres-cluster via CNPG cluster Helm chart
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    # ── Preflight checks ──────────────────────────────────────────────────
    kubectl get crd clustersecretstores.external-secrets.io &>/dev/null || \
      { gum style --foreground 196 "ESO not installed — run: just eso::install"; exit 1; }

    # ── Install CNPG operator ─────────────────────────────────────────────
    gum style --bold --foreground 212 "Installing CloudNativePG operator..."
    helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update 2>/dev/null
    helm repo update cnpg

    kubectl create namespace {{CNPG_NS}} --dry-run=client -o yaml | kubectl apply -f -
    # CNPG operator itself needs privileged; cluster pods run restricted
    kubectl label namespace {{CNPG_NS}} \
      pod-security.kubernetes.io/enforce=privileged \
      pod-security.kubernetes.io/warn=baseline --overwrite

    helm upgrade --install cnpg cnpg/cloudnative-pg \
      --namespace {{CNPG_NS}} \
      --values "{{DIR}}/cnpg-values.yaml" \
      --wait --timeout 5m

    gum style --foreground 46 "  ✓ CNPG operator installed"

    # ── Generate admin password → Vault ──────────────────────────────────
    gum style --bold --foreground 212 "Storing admin credentials in Vault..."
    # Check if already set (idempotent)
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    VAULT_OUT=$(kubectl -n vault exec vault-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" vault kv get -format=json secret/postgres/admin \
      2>/dev/null || true)
    EXISTING=$(echo "$VAULT_OUT" | jq -r ".data.data.password" 2>/dev/null || echo "")

    if [ -z "$EXISTING" ]; then
      PG_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
      kubectl -n vault exec vault-0 -- \
        env VAULT_TOKEN="$ROOT_TOKEN" \
        vault kv put secret/postgres/admin \
          username=postgres \
          password="$PG_PASSWORD"
      gum style --foreground 46 "  ✓ Admin credentials written to Vault at secret/postgres/admin"
    else
      gum style --foreground 244 "  · Admin credentials already in Vault — skipping"
    fi

    # ── ExternalSecret → k8s Secret ──────────────────────────────────────
    gum style --bold --foreground 212 "Syncing credentials via ExternalSecret..."
    kubectl apply -f "{{DIR}}/superuser-external-secret.yaml"
    kubectl wait --for=condition=Ready externalsecret/postgres-cluster-superuser \
      -n {{CNPG_NS}} --timeout=60s
    gum style --foreground 46 "  ✓ ExternalSecret synced"

    # ── Create postgres-cluster ───────────────────────────────────────────
    gum style --bold --foreground 212 "Creating postgres-cluster..."
    helm upgrade --install postgres-cluster cnpg/cluster \
      --namespace {{CNPG_NS}} \
      --values "{{DIR}}/cluster-values.yaml" \
      --wait --timeout 5m

    gum style --bold --foreground 212 "Waiting for PostgreSQL cluster to be ready..."
    kubectl wait --for=condition=Ready clusters.postgresql.cnpg.io/postgres-cluster \
      -n {{CNPG_NS}} --timeout=300s

    gum style --foreground 46 "  ✓ PostgreSQL cluster ready"
    gum style --foreground 244 "  · Connect: just postgres::psql"
    gum style --foreground 244 "  · Create app DB: just postgres::create-user-db <app>"

# Show cluster status
status:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl get clusters.postgresql.cnpg.io -n {{CNPG_NS}}
    echo ""
    kubectl get pods -n {{CNPG_NS}}

# Open an interactive psql session on the primary
psql *args='':
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl exec -it -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- psql {{ args }}

# Print the admin password
admin-password:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl get -n {{CNPG_NS}} secret postgres-cluster-superuser \
      -o jsonpath="{.data.password}" | base64 --decode
    echo

# Create a database + user + grant all privileges
# just postgres::create-user-db myapp
# Credentials are auto-generated and stored in Vault at secret/postgres/<app>
create-user-db app:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    APP="{{ app }}"
    DB_NAME="${APP}"
    DB_USER="${APP}"

    # Generate password and store in Vault
    ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o json \
      | jq -r ".data[\"init.json\"]" | base64 -d | jq -r ".root_token")
    VAULT_OUT=$(kubectl -n vault exec vault-0 -- \
      env VAULT_TOKEN="$ROOT_TOKEN" vault kv get -format=json "secret/postgres/${APP}" \
      2>/dev/null || true)
    EXISTING=$(echo "$VAULT_OUT" | jq -r ".data.data.password" 2>/dev/null || echo "")

    if [ -z "$EXISTING" ]; then
      DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
      kubectl -n vault exec vault-0 -- \
        env VAULT_TOKEN="$ROOT_TOKEN" \
        vault kv put "secret/postgres/${APP}" \
          username="${DB_USER}" \
          password="${DB_PASSWORD}" \
          database="${DB_NAME}" \
          host="postgres-cluster-rw.postgres.svc.cluster.local"
      gum style --foreground 46 "  ✓ Credentials stored in Vault at secret/postgres/${APP}"
    else
      DB_PASSWORD="$EXISTING"
      gum style --foreground 244 "  · Credentials already in Vault — reusing"
    fi

    # Create DB if not exists
    DB_EXISTS=$(kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" 2>/dev/null || echo "")
    if [ "$DB_EXISTS" != "1" ]; then
      kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
        psql -U postgres -c "CREATE DATABASE ${DB_NAME};"
      gum style --foreground 46 "  ✓ Database '${DB_NAME}' created"
    else
      gum style --foreground 244 "  · Database '${DB_NAME}' already exists"
    fi

    # Create user if not exists
    USER_EXISTS=$(kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';" 2>/dev/null || echo "")
    if [ "$USER_EXISTS" != "1" ]; then
      kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
        psql -U postgres -c "CREATE USER ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';"
      gum style --foreground 46 "  ✓ User '${DB_USER}' created"
    else
      kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
        psql -U postgres -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
      gum style --foreground 244 "  · User '${DB_USER}' already exists — password updated"
    fi

    # Grant privileges
    kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
    kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -d "${DB_NAME}" -c "GRANT CREATE ON SCHEMA public TO ${DB_USER};"

    gum style --foreground 46 "  ✓ Database '${DB_NAME}' ready for app '${APP}'"
    gum style --foreground 244 "  · Host: postgres-cluster-rw.postgres.svc.cluster.local:5432"
    gum style --foreground 244 "  · Vault path: secret/postgres/${APP}"

# Delete a database and user — just postgres::delete-user-db myapp
delete-user-db app:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    APP="{{ app }}"
    gum confirm "Delete database and user '${APP}'? All data will be lost." || exit 0

    kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- psql -U postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${APP}';" 2>/dev/null || true
    kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -c "DROP DATABASE IF EXISTS ${APP};"
    kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -c "DROP USER IF EXISTS ${APP};"

    gum style --foreground 46 "  ✓ Database and user '${APP}' deleted"
    gum style --foreground 244 "  · Vault credentials at secret/postgres/${APP} were NOT deleted"
    gum style --foreground 244 "  · To remove: just vault::delete secret/postgres/${APP}"

# List all databases (excluding system databases)
list-dbs:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    kubectl exec -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      psql -U postgres -c "\l"

# Dump a database to a local file — just postgres::dump myapp ./backup.dump
dump app file:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    PG_PASS=$(kubectl get -n {{CNPG_NS}} secret postgres-cluster-superuser \
      -o jsonpath="{.data.password}" | base64 --decode)
    kubectl exec -i -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- bash -c \
      "pg_dump -d postgresql://postgres:${PG_PASS}@localhost/{{ app }} -Fc > /var/lib/postgresql/data/db.dump"
    kubectl cp -n {{CNPG_NS}} -c postgres \
      postgres-cluster-1:/var/lib/postgresql/data/db.dump "{{ file }}"
    kubectl exec -i -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      rm /var/lib/postgresql/data/db.dump
    gum style --foreground 46 "  ✓ Dumped '{{ app }}' to {{ file }}"

# Restore a database from a local dump — just postgres::restore myapp ./backup.dump
restore app file:
    #!/usr/bin/env bash
    set -euo pipefail
    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG
    PG_PASS=$(kubectl get -n {{CNPG_NS}} secret postgres-cluster-superuser \
      -o jsonpath="{.data.password}" | base64 --decode)
    kubectl cp "{{ file }}" -n {{CNPG_NS}} -c postgres \
      postgres-cluster-1:/var/lib/postgresql/data/db.dump
    kubectl exec -i -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- bash -c \
      "pg_restore --clean --if-exists \
       -d postgresql://postgres:${PG_PASS}@localhost/{{ app }} \
       /var/lib/postgresql/data/db.dump"
    kubectl exec -i -n {{CNPG_NS}} postgres-cluster-1 -c postgres -- \
      rm /var/lib/postgresql/data/db.dump
    gum style --foreground 46 "  ✓ Restored '{{ app }}' from {{ file }}"

# Uninstall postgres-cluster and CNPG operator
# WARNING: destroys all data unless you dumped first
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum confirm "Destroy postgres-cluster and all its data?" || exit 0

    kubectl delete externalsecret postgres-cluster-superuser -n {{CNPG_NS}} --ignore-not-found 2>/dev/null || true
    helm uninstall postgres-cluster -n {{CNPG_NS}} 2>/dev/null || true
    helm uninstall cnpg -n {{CNPG_NS}} 2>/dev/null || true
    kubectl get crd -o name | grep postgresql.cnpg.io | \
      xargs --no-run-if-empty kubectl delete --ignore-not-found 2>/dev/null || true
    kubectl delete namespace {{CNPG_NS}} --ignore-not-found

    gum style --foreground 46 "  ✓ PostgreSQL cluster and operator removed"
