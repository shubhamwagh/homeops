# PostgreSQL

CloudNativePG (CNPG) operator managing a single-instance PostgreSQL 16 cluster on Longhorn storage. Admin credentials managed via Vault + ESO.

## Prerequisites

- Longhorn installed (`just longhorn::install`)
- Vault installed and configured (`just vault::install`)
- ESO installed (`just eso::install`)

## Install

```sh
just postgres::install
```

What happens:
1. Installs the CNPG operator via Helm in the `postgres` namespace
2. Generates a random admin password → stores at `secret/postgres/admin` in Vault
3. ESO ExternalSecret syncs credentials into `postgres-cluster-superuser` k8s Secret
4. Creates the `postgres-cluster` CNPG Cluster (single instance, 20Gi on Longhorn)

## Recipes

| Recipe | Description |
|---|---|
| `just postgres::install` | Install CNPG operator + create cluster |
| `just postgres::status` | Show cluster and pod status |
| `just postgres::psql [args]` | Interactive psql session on the primary |
| `just postgres::admin-password` | Print the admin password |
| `just postgres::create-user-db <app>` | Create a database + user for an app |
| `just postgres::delete-user-db <app>` | Drop a database and user |
| `just postgres::list-dbs` | List all databases |
| `just postgres::dump <app> <file>` | Dump a database to a local file |
| `just postgres::restore <app> <file>` | Restore a database from a local dump |
| `just postgres::uninstall` | Destroy the cluster and operator |

## Creating an App Database

```sh
# Creates DB, user, and stores credentials in Vault at secret/postgres/myapp
just postgres::create-user-db myapp
```

This automatically:
- Generates a random 32-char password
- Stores `username`, `password`, `database`, `host` at `secret/postgres/myapp` in Vault
- Creates the PostgreSQL database and user
- Grants full privileges

The app can then pull credentials with an `ExternalSecret`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-db
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: myapp-db
  data:
    - secretKey: username
      remoteRef:
        key: secret/postgres/myapp
        property: username
    - secretKey: password
      remoteRef:
        key: secret/postgres/myapp
        property: password
    - secretKey: database
      remoteRef:
        key: secret/postgres/myapp
        property: database
    - secretKey: host
      remoteRef:
        key: secret/postgres/myapp
        property: host
```

## Connection Details

| | Value |
|---|---|
| Host (in-cluster) | `postgres-cluster-rw.postgres.svc.cluster.local` |
| Port | `5432` |
| Read-write service | `postgres-cluster-rw` |
| Read-only service | `postgres-cluster-ro` |

## Backup and Restore

```sh
# Dump to local file
just postgres::dump myapp ./myapp-backup.dump

# Restore from local file
just postgres::restore myapp ./myapp-backup.dump
```

## Troubleshooting

```sh
# Check cluster status
just postgres::status

# Open psql shell
just postgres::psql

# Run SQL directly
just postgres::psql -- -c "\l"

# Check CNPG operator logs
kubectl logs -n postgres -l app.kubernetes.io/name=cloudnative-pg
```
