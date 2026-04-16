# External Secrets Operator (ESO)

Syncs secrets from Vault KV-v2 into native Kubernetes Secrets. Apps reference a `ClusterSecretStore` named `vault` — ESO fetches the values from Vault automatically.

## Prerequisites

- Vault installed, unsealed, and configured (`just vault::install`)

## Install

```sh
just eso::install
```

What happens:
1. Installs ESO via Helm in the `external-secrets` namespace
2. Creates a Vault Kubernetes auth role `external-secrets` with `admin` policy
3. Applies a `ClusterSecretStore` pointing to `http://vault.vault.svc:8200`
4. Waits for the ClusterSecretStore to become `Ready`

## Recipes

| Recipe | Description |
|---|---|
| `just eso::install` | Install ESO + configure Vault ClusterSecretStore |
| `just eso::status` | Show ClusterSecretStore and all ExternalSecrets |
| `just eso::sync <namespace>` | Force-sync all ExternalSecrets in a namespace |
| `just eso::uninstall` | Remove ESO and ClusterSecretStore |

## Using ESO in an App

Write the secret to Vault first:

```sh
just vault::put secret/myapp/db password=s3cr3t api_key=abc123
```

Then create an `ExternalSecret` in your app's namespace:

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
    name: myapp-db          # name of the k8s Secret to create
  data:
    - secretKey: password   # key in the k8s Secret
      remoteRef:
        key: secret/myapp/db
        property: password
    - secretKey: api_key
      remoteRef:
        key: secret/myapp/db
        property: api_key
```

ESO creates `myapp-db` Secret in the `myapp` namespace, kept in sync every hour.

## Secret Path Format

Vault KV-v2 path convention used in this cluster:

```
secret/<component>/<name>
```

Examples:
- `secret/postgres/admin` — PostgreSQL superuser
- `secret/postgres/keycloak` — keycloak DB credentials
- `secret/keycloak/admin` — Keycloak admin credentials
- `secret/myapp/config` — your app's config secrets

## Force Sync

If you update a secret in Vault and need it reflected immediately:

```sh
just eso::sync myapp-namespace
```

## Troubleshooting

```sh
# Check ClusterSecretStore health
just eso::status

# Describe a failing ExternalSecret
kubectl describe externalsecret myapp-db -n myapp

# Check ESO logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```
