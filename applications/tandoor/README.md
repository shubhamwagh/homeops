# Tandoor

Recipe manager and shopping list app. Uses the shared CNPG PostgreSQL cluster with credentials managed via Vault + ESO. Supports Keycloak SSO via `django-allauth`.

## Prerequisites

- PostgreSQL installed (`just postgres::install`)
- Vault + ESO installed
- Gateway installed (`just gateway::install`)
- Keycloak installed (`just keycloak::install`) — for SSO

## Install

```sh
just tandoor::install
```

What happens:
1. Creates `tandoor` database in CNPG (`just postgres::create-user-db tandoor`)
2. Generates a Django `SECRET_KEY` → stores at `secret/tandoor/config` in Vault
3. ESO ExternalSecret syncs secrets into `tandoor-secret` in the `tandoor` namespace
4. Deploys Tandoor with an nginx sidecar; init container runs Django migrations
5. Applies HTTPRoute → `https://tandoor.home.didcot`

## Recipes

| Recipe | Description |
|---|---|
| `just tandoor::install` | Full install |
| `just tandoor::uninstall` | Remove Tandoor (DB preserved) |

## SSO (Keycloak)

Create a confidential OIDC client and store it in Vault:

```sh
SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
just keycloak::create-client homelab tandoor "https://tandoor.home.didcot/*" "$SECRET"
just vault::put secret/tandoor/oidc socialaccount_providers='{"openid_connect":{"SERVERS":[{"id":"keycloak","name":"Keycloak","server_url":"https://keycloak.home.didcot/realms/homelab","APP":{"client_id":"tandoor","secret":"'$SECRET'"}}]}}'
```

The deployment pulls `SOCIALACCOUNT_PROVIDERS` from Vault via ESO and sets `REQUESTS_CA_BUNDLE` to trust the homelab CA.

## Vault Secrets

| Path | Keys |
|---|---|
| `secret/postgres/tandoor` | `username`, `password`, `database`, `host` |
| `secret/tandoor/config` | `secret_key` |
| `secret/tandoor/oidc` | `socialaccount_providers` (JSON) |

## CA Trust

Tandoor makes HTTPS calls to Keycloak for OIDC. The homelab CA is mounted from `homelab-ca-secret` and set via `REQUESTS_CA_BUNDLE=/etc/ssl/homelab/ca.crt`.

## Uninstall

```sh
just tandoor::uninstall

# Optionally remove all data (destructive)
just postgres::delete-user-db tandoor
just vault::delete secret/tandoor/config
just vault::delete secret/tandoor/oidc
just vault::delete secret/postgres/tandoor
```
