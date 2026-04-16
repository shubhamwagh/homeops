#!/usr/bin/env bash
# Vault post-install configuration — runs once after init+unseal
# Follows buun-stack pattern: dedicated vault-auth SA for k8s auth reviewer
set -euo pipefail

VAULT_NS="${VAULT_NS:-vault}"

vault_exec() {
  kubectl -n "$VAULT_NS" exec -i vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault "$@"
}

# ── Get root token ─────────────────────────────────────────────────────────────
INIT_JSON=$(kubectl -n "$VAULT_NS" get secret vault-unseal-keys -o json \
  | jq -r '.data["init.json"]' | base64 -d)
ROOT_TOKEN=$(echo "$INIT_JSON" | jq -r '.root_token')

# ── KV-v2 ─────────────────────────────────────────────────────────────────────
vault_exec secrets enable -path=secret kv-v2 2>/dev/null \
  && echo "  + KV-v2 enabled at secret/" \
  || echo "  - KV-v2 already enabled"

# ── Kubernetes auth ────────────────────────────────────────────────────────────
vault_exec auth enable kubernetes 2>/dev/null \
  && echo "  + Kubernetes auth enabled" \
  || echo "  - Kubernetes auth already enabled"

# Use dedicated vault-auth SA token (buun-stack pattern — not the pod's own JWT)
SA_JWT=$(kubectl get secret -n "$VAULT_NS" vault-auth-token \
  -o jsonpath='{.data.token}' | base64 -d)
SA_CA=$(kubectl get secret -n "$VAULT_NS" vault-auth-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

vault_exec write auth/kubernetes/config \
  token_reviewer_jwt="$SA_JWT" \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert="$SA_CA"
echo "  + Kubernetes auth configured (vault-auth SA)"

# ── Admin policy (full access — for ESO, operators, admin tooling) ────────────
vault_exec policy write admin - <<'EOF'
path "sys/auth" {
  capabilities = ["read", "list", "sudo"]
}
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policy/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/token/create" {
  capabilities = ["create", "update"]
}
path "auth/token/create/*" {
  capabilities = ["create", "update"]
}
EOF
echo "  + admin policy written"

# ── Default read policy (apps get their own scoped policies) ───────────────────
vault_exec policy write default-read - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "  + default-read policy written"

echo "Vault configuration complete."
