# homeops

Bare-metal k3s homelab — GitOps with FluxCD, SOPS+age secrets, Cilium CNI, Traefik, cert-manager, Longhorn, and Prometheus.

## Full Setup (fresh nodes → running cluster)

```bash
# 1. Install tools (once)
make tools

# 2. Configure cluster — enter node IPs, SSH key, cluster name
make configure

# 3. Install k3s + Cilium CNI
make bootstrap

# 4. Bootstrap GitOps — secrets, sops key, flux (GITHUB_TOKEN must be in env)
make gitops
```

After step 4, Flux reconciles the repo and deploys everything automatically.

> Save passwords from `.secrets-plaintext` to 1Password, then `rm .secrets-plaintext`.

## Teardown + Rebuild

```bash
make teardown    # wipe k3s from all nodes
make bootstrap   # reinstall k3s + cilium
make gitops      # re-encrypt secrets + flux bootstrap
```

`age.agekey` is preserved across teardown — back it up to 1Password once and never lose it.

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
| TLS | cert-manager | v1.17.2 |
| Storage | Longhorn | 1.7.2 |
| Monitoring | kube-prometheus-stack | 79.* |
| Controllers | Reloader, Renovate | - |
| GitOps | FluxCD | - |
| Secrets | SOPS + age | - |

## Apps

| App | Description |
|---|---|
| Homepage | Dashboard |
| Tandoor | Recipe manager |

## Renovate

Renovate bot runs daily at 2am and opens PRs for outdated Helm chart versions. A Dependency Dashboard issue is created on the repo — use it to trigger manual runs or approve updates.

## Prerequisites

- Ubuntu nodes reachable via SSH
- macOS with Homebrew
- `GITHUB_TOKEN` env var (GitHub PAT with `repo` scope)
- GitHub repo at `shubhamwagh/homeops`
