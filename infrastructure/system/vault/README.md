# Vault

HashiCorp Vault for secrets management. Single-replica, Raft storage on Longhorn. KV-v2 + Kubernetes auth.

## Prerequisites

- Longhorn installed (`just longhorn::install`)
- cert-manager installed with homelab CA (`just cert-manager::install`)
- Gateway installed (`just gateway::install`)

## Install

```sh
just vault::install
```

What happens:
1. Helm installs Vault in the `vault` namespace
2. On first run: initialises with 1 key share / 1 threshold → unseal key stored in `vault/vault-unseal-keys` k8s secret
3. Unseals `vault-0`
4. Configures KV-v2 secret engine, Kubernetes auth, `admin` and `default-read` policies
5. Applies HTTPRoute → `https://vault.home.didcot`

Subsequent runs are **idempotent** — re-running is safe.

## Recipes

| Recipe | Description |
|---|---|
| `just vault::install` | Install + initialise + unseal + configure |
| `just vault::unseal` | Unseal vault-0 (run after every cluster restart) |
| `just vault::token` | Print the root token (for UI login) |
| `just vault::status` | Show seal/HA status |
| `just vault::get <path>` | Read a KV-v2 secret |
| `just vault::put <path> key=val …` | Write a KV-v2 secret |
| `just vault::delete <path>` | Delete a KV-v2 secret |
| `just vault::list <path>` | List secrets at a path |
| `just vault::write-policy <name> <file.hcl>` | Upload a policy from a local HCL file |
| `just vault::create-role <role> <sa> <ns> <policy>` | Create a Kubernetes auth role |
| `just vault::uninstall` | Remove Vault and all data |

## Examples

```sh
# Read a secret
just vault::get secret/postgres/keycloak

# Write a secret
just vault::put secret/myapp/db host=postgres.svc password=s3cr3t

# Unseal after cluster restart
just vault::unseal

# Use 1Password for unseal key (instead of k8s secret)
VAULT_UNSEAL_KEY=op://homelab/vault-unseal/key just vault::unseal

# Create a Kubernetes auth role for an app
just vault::create-role myapp myapp-sa myapp admin
```

## Secret Layout

```
secret/
├── postgres/
│   ├── admin        # PostgreSQL superuser (username, password)
│   ├── keycloak     # keycloak DB creds (username, password, database, host)
│   └── <app>        # per-app DB creds (created by just postgres::create-user-db)
└── keycloak/
    └── admin        # Keycloak admin credentials (username, password)
```

## Policies

| Policy | Paths |
|---|---|
| `admin` | `secret/*` full CRUD, `sys/auth` read/list/sudo, `auth/token/create` |
| `default-read` | `secret/*` read + list only |

## After Cluster Restart

Vault is sealed after every pod restart. Run:

```sh
just vault::unseal
```

Or automate with 1Password:
```sh
VAULT_UNSEAL_KEY=op://homelab/vault-unseal/key just vault::unseal
```

## UI

`https://vault.home.didcot` — login with root token (`just vault::token`) or via OIDC after `just keycloak::setup-vault-oidc`.
