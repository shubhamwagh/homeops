# cert-manager

TLS certificate management for the cluster. Creates a self-signed homelab CA that signs all `*.home.didcot` certificates. The CA is trusted on macOS via Keychain.

## Prerequisites

- Cilium installed (`just cilium::install`)

## Install

```sh
just cert-manager::install
just cert-manager::trust-ca   # trust the CA on your Mac
```

What happens:
1. Installs cert-manager v1.17.2 via Helm in the `cert-manager` namespace
2. Creates a `ClusterIssuer` → generates the `Didcot Homelab CA` certificate
3. `trust-ca` exports the CA cert and adds it to macOS System Keychain

After `trust-ca`, all `*.home.didcot` services show a padlock in the browser.

## Recipes

| Recipe | Description |
|---|---|
| `just cert-manager::install` | Install cert-manager + create homelab CA |
| `just cert-manager::trust-ca` | Export CA and trust it on macOS |
| `just cert-manager::untrust-ca` | Remove CA from macOS Keychain |
| `just cert-manager::uninstall` | Remove cert-manager (also runs untrust-ca) |

## Python / CLI Tools

`trust-ca` also builds `~/.homelab-ca-bundle.pem` and adds to `~/.zshrc`:

```sh
export REQUESTS_CA_BUNDLE=~/.homelab-ca-bundle.pem
export SSL_CERT_FILE=~/.homelab-ca-bundle.pem
```

This ensures tools like `curl`, `requests`, SkyPilot, and other Python HTTP clients trust homelab certs. Run `source ~/.zshrc` or open a new terminal after.

## Issuing Certificates

cert-manager automatically issues certificates for any `Certificate` resource referencing `homelab-ca-issuer`. The gateway components handle this automatically via `TLSRoute` / `HTTPRoute` annotations.

To manually verify:
```sh
kubectl get certificate -A
kubectl get clusterissuer
```
