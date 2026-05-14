# homeops

Bare-metal k3s homelab - GitOps with FluxCD, SOPS+age secrets, Cilium CNI, Traefik, cert-manager, Longhorn, and Prometheus.

## Prerequisites

Before running setup:

- Ubuntu nodes reachable via SSH (see `infrastructure/metal/README.md`)
- Homebrew installed on control machine
- A domain registered on **Cloudflare** (e.g. `shublab.com`)
- Two env vars set:
  ```bash
  export GITHUB_TOKEN=ghp_xxx        # GitHub PAT with repo scope
  export CLOUDFLARE_TOKEN=cfut_xxx   # Cloudflare API token - Edit zone DNS
  ```

### Cloudflare Setup (one-time)

1. Register domain at [cloudflare.com/registrar](https://cloudflare.com/registrar)
2. Go to **My Profile → API Tokens → Create Token**
3. Use template **"Edit zone DNS"**, scope to your domain
4. Copy the token → set as `CLOUDFLARE_TOKEN` env var
5. After cluster is up, add DNS record:
   - Type: `A` | Name: `*` | Content: `192.168.0.2` | Proxy: off

This makes all services accessible at `*.shublab.com` with trusted Let's Encrypt TLS.

## Full Setup (fresh nodes → running cluster)

```bash
# 1. Install tools (once)
make tools

# 2. Configure cluster - enter node IPs, SSH key, cluster name
make configure

# 3. Install k3s + Cilium CNI
make bootstrap

# 4. Bootstrap GitOps - generates+encrypts all secrets, bootstraps Flux
make gitops
```

After step 4, Flux reconciles the repo and deploys everything automatically.
Back up `.secrets-plaintext` securely, then `rm .secrets-plaintext`.

## Teardown + Rebuild

```bash
make teardown    # wipe k3s from all nodes
make bootstrap   # reinstall k3s + cilium
make gitops      # re-encrypt secrets + flux bootstrap
```

`age.agekey` is preserved across teardown - back it up securely and never lose it.

## Day-to-day

```bash
make flux-status    # show all Flux resources
make flux-sync      # force reconcile from git
make nodes          # kubectl get nodes -o wide
```

## Stack

| Layer | Tool | Version |
|---|---|---|
| CNI + L2 LB | Cilium | 1.17.3 |
| Ingress | Traefik | 32.1.0 |
| TLS | cert-manager + Let's Encrypt | v1.17.2 |
| DNS | Cloudflare (DNS-01 challenge) | - |
| TLS sync | Reflector | 9.* |
| Storage | Longhorn | 1.7.2 |
| Monitoring | kube-prometheus-stack | 79.* |
| Security | CrowdSec | 0.12.* |
| Controllers | Reloader, Renovate | - |
| GitOps | FluxCD | - |
| Secrets | SOPS + age | - |

## Services

| Service | URL | Description |
|---|---|---|
| Homepage | `home.shublab.com` | Dashboard |
| Grafana | `grafana.shublab.com` | Metrics + dashboards |
| Longhorn | `longhorn.shublab.com` | Storage UI |
| Traefik | `traefik.shublab.com` | Ingress dashboard |
| Vaultwarden | `vault.shublab.com` | Password manager |
| SearXNG | `search.shublab.com` | Private search engine |
| Tandoor | `tandoor.shublab.com` | Recipe manager |

## Renovate

Renovate bot runs daily at 2am and opens PRs for outdated Helm chart versions.
Check the Dependency Dashboard issue on GitHub to trigger manual runs or approve updates.
