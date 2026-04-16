# Keycloak

Identity provider for SSO. Backs authentication for Vault UI, kubectl (k8s OIDC), and all cluster apps. Uses PostgreSQL for persistence, credentials managed via Vault + ESO.

## Prerequisites

- PostgreSQL installed (`just postgres::install`)
- Vault + ESO installed
- Gateway installed and reachable at `*.home.didcot`

## Install

```sh
just keycloak::install
```

What happens:
1. Creates `keycloak` database in PostgreSQL (`just postgres::create-user-db keycloak`)
2. Generates admin password → stores at `secret/keycloak/admin` in Vault
3. ESO syncs admin + DB credentials into the `keycloak` namespace
4. Deploys Keycloak via plain manifests using `quay.io/keycloak/keycloak` (external PostgreSQL, `KC_PROXY_HEADERS=xforwarded` for TLS offload)
5. Applies HTTPRoute → `https://keycloak.home.didcot`
6. Creates the `homelab` realm (token lifespans: 12h access / 7d refresh)
7. Creates the `admins` group

## Recipes

### Admin

| Recipe | Description |
|---|---|
| `just keycloak::install` | Full install with realm + group bootstrap |
| `just keycloak::admin-password` | Print admin password |
| `just keycloak::uninstall` | Remove Keycloak (DB not deleted) |

### Realm & Client Management

| Recipe | Description |
|---|---|
| `just keycloak::create-realm <realm>` | Create a realm |
| `just keycloak::create-client <realm> <client-id> <redirect-urls> [secret]` | Create OIDC client |
| `just keycloak::delete-client <realm> <client-id>` | Delete a client |
| `just keycloak::get-client-secret <realm> <client-id>` | Get a client's secret |
| `just keycloak::add-audience-mapper <realm> <client-id> <audience>` | Add audience mapper to JWT |
| `just keycloak::add-groups-mapper <realm> <client-id>` | Add groups claim to JWT |

### User & Group Management

| Recipe | Description |
|---|---|
| `just keycloak::create-user <realm> <username> <email> [password]` | Create a user |
| `just keycloak::create-group <realm> <group>` | Create a group |
| `just keycloak::add-user-to-group <realm> <username> <group>` | Add user to group |

### OIDC Wiring

| Recipe | Description |
|---|---|
| `just keycloak::setup-vault-oidc` | Wire Vault OIDC login to Keycloak |
| `just keycloak::setup-k8s-oidc` | Wire kubectl OIDC login to Keycloak |

## Setting Up SSO for an App

```sh
# Create OIDC client
just keycloak::create-client homelab grafana "https://grafana.home.didcot/*"

# Add mappers so JWT contains audience and groups
just keycloak::add-audience-mapper homelab grafana grafana
just keycloak::add-groups-mapper   homelab grafana

# Get the client secret (pass to app's config)
just keycloak::get-client-secret homelab grafana
```

## Adding a User

```sh
# Create user (password auto-generated if omitted)
just keycloak::create-user homelab john john@home.didcot

# Add to admins group (gives cluster-admin via k8s OIDC)
just keycloak::add-user-to-group homelab john admins
```

## Vault OIDC

After install:

```sh
just keycloak::setup-vault-oidc
```

Members of the `admins` Keycloak group get `admin` Vault policy. All other users get `default-read`.

Login from CLI:
```sh
vault login -method=oidc -address=https://vault.home.didcot
```

## Kubernetes OIDC (kubectl)

```sh
just keycloak::setup-k8s-oidc
```

This:
- Creates a `kubernetes` OIDC client in Keycloak
- Writes `/etc/rancher/k3s/config.yaml.d/oidc.yaml` on each control-plane node
- Restarts k3s (rolling, one node at a time)
- Applies RBAC: `oidc:admins` → `cluster-admin`, `oidc:viewers` → `view`

Configure kubelogin after:
```sh
kubectl oidc-login setup \
  --oidc-issuer-url=https://keycloak.home.didcot/realms/homelab \
  --oidc-client-id=kubernetes \
  --oidc-client-secret=<secret-from-setup-output>
```

## URLs

| | URL |
|---|---|
| Admin UI | `https://keycloak.home.didcot/admin` |
| Realm issuer | `https://keycloak.home.didcot/realms/homelab` |
| OIDC discovery | `https://keycloak.home.didcot/realms/homelab/.well-known/openid-configuration` |

## Scripts

TypeScript automation scripts in `scripts/` use `@keycloak/keycloak-admin-client`. Run with **Bun** (no transpile step needed). Dependencies are installed automatically on first `just keycloak::install`.

To install manually:
```sh
bun install --cwd infrastructure/system/keycloak/scripts
```

## CA Trust

Apps inside the cluster that call `https://keycloak.home.didcot` must trust the homelab CA. Set `REQUESTS_CA_BUNDLE` (Python) or mount the CA cert from `homelab-ca-secret` in `cert-manager`.

Export the CA cert for devices:
```sh
kubectl get secret homelab-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
```
