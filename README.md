# homeops

Bare-metal k3s homelab — GitOps with FluxCD, SOPS secrets, Cilium CNI, Traefik, cert-manager, Longhorn, and Prometheus.

## Full Setup (fresh nodes → running cluster)

```bash
# 1. Install tools
make tools

# 2. Configure cluster (interactive — enter node IPs, SSH key, cluster name)
make configure

# 3. Install k3s + Cilium CNI
make bootstrap

# 4. Bootstrap GitOps (generates secrets, uploads age key, bootstraps Flux)
GITHUB_TOKEN=ghp_xxx make gitops
```

After step 4, Flux reconciles the repo and deploys everything automatically.

> **After `make gitops`:** save passwords from `.secrets-plaintext` to 1Password, then `rm .secrets-plaintext`.

## Day-to-day

```bash
make flux-status    # show all Flux resources
make flux-sync      # force reconcile from git
make nodes          # kubectl get nodes -o wide
```

## Stack

| Layer | Tool |
|---|---|
| CNI + L2 LB | Cilium |
| Ingress | Traefik |
| TLS | cert-manager (self-signed CA) |
| Storage | Longhorn |
| Monitoring | kube-prometheus-stack + Grafana |
| Controllers | Reloader, Renovate |
| GitOps | FluxCD |
| Secrets | SOPS + age |

## Prerequisites

- Ubuntu nodes reachable via SSH
- macOS with Homebrew (`brew bundle` installs: mise, age, sops, flux, jq, yq, stern)
- GitHub repo (Flux bootstraps from `clusters/staging`)
