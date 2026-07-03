# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What This Repo Does

Bare-metal k3s homelab - GitOps with FluxCD, SOPS+age secrets, Cilium CNI+L2LB, Traefik ingress, cert-manager + Let's Encrypt, Longhorn storage, kube-prometheus-stack. Task runner is `make`.

## Running Things

```bash
make tools              # install tools via brew + mise (first-time)
make configure          # interactive setup - writes inventory + group_vars (gitignored)
make bootstrap          # k3s install + copy kubeconfig + cilium
make gitops             # generate+encrypt secrets, commit, upload sops key, flux bootstrap
                        # requires GITHUB_TOKEN + CLOUDFLARE_TOKEN in env
make teardown           # uninstall k3s, clean .secrets-plaintext (keeps age.agekey)
make nodes              # kubectl get nodes -o wide
make flux-status        # flux get all -A
make flux-sync          # force reconcile from git
```

## Tool Stack

| Tool | Role |
|---|---|
| `mise` | Pins tool versions (see `mise.toml`) |
| `make` | Task runner - only interface needed |
| `ansible` + `k3sup` | Provisions k3s over SSH |
| `flux` | GitOps controller |
| `sops` + `age` | Encrypt secrets committed to git |
| `helm` / `kubectl` | Cluster interaction |
| `yq` | Reads inventory for copy-kubeconfig |

## Architecture

- **No just/gum/gomplate** - replaced by Makefile + plain bash
- **Ansible runs locally** - playbooks delegate_to localhost, invoke k3sup over SSH
- **Config is generated** - `infrastructure/metal/inventory.yml` and `group_vars/all.yml` written by `make configure`, gitignored
- **Cilium chicken-and-egg** - bootstrapped via Helm BEFORE Flux, pods need CNI to start
- **SOPS + age** - all secrets committed as `*.sops.yaml`, decrypted by Flux using `sops-age` k8s Secret
- **CRD ordering** - `infrastructure` (HelmReleases, wait:true) → `infrastructure-config` (CRD-dependent) → `apps`
- **TLS** - Let's Encrypt wildcard `*.shublab.com` via cert-manager + Cloudflare DNS-01. Reflector syncs secret across all namespaces.
- **Renovate** - daily 2am PRs, repo=shubhamwagh/homeops, token in `renovate-github-token` secret

## Project Structure

```
homeops/
├── Makefile                        # all tasks
├── Brewfile                        # brew deps: mise, age, sops, flux, jq, yq, stern
├── mise.toml                       # pinned: kubectl, helm, stern, age, sops, ansible, k3sup
├── .sops.yaml                      # age public key for secret encryption
├── clusters/staging/               # Flux entry point
│   ├── flux-system/                # gotk-components (managed by flux bootstrap)
│   ├── infrastructure.yaml         # path: infrastructure/staging, wait:true
│   ├── infrastructure-config.yaml  # dependsOn: infrastructure (CRD-dependent resources)
│   └── apps.yaml                   # dependsOn: infrastructure + infrastructure-config
├── infrastructure/
│   ├── base/
│   │   ├── networking/             # cilium, traefik, cert-manager (+ cloudflare secret)
│   │   ├── storage/                # longhorn (+ servicemonitor, recurring-jobs)
│   │   ├── monitoring/             # kube-prometheus-stack, metrics-server
│   │   ├── controllers/            # reloader, renovate, reflector
│   │   ├── security/               # crowdsec, vaultwarden
│   │   └── searxng/                # self-hosted search engine
│   ├── config/
│   │   ├── base/                   # cert-manager ClusterIssuers + wildcard cert, Traefik Middleware
│   │   └── staging/
│   └── metal/                      # ansible: inventory.yml (gitignored), playbooks/
└── apps/
    ├── base/
    │   ├── homepage/               # dashboard - shows all services
    │   ├── tandoor/                # recipe manager (needs postgres - TODO)
    │   └── trek/                   # travel planner (sqlite, own PVC)
    └── staging/
```

## Secrets

All secrets are `*.sops.yaml` files encrypted with age. Never commit plaintext.

| Secret | Namespace | Contents |
|---|---|---|
| `grafana-admin-secret` | `monitoring` | grafana admin password |
| `tandoor-secret` | `tandoor` | SECRET_KEY, POSTGRES_PASSWORD |
| `renovate-github-token` | `renovate` | RENOVATE_TOKEN (GitHub PAT) |
| `cloudflare-api-token` | `cert-manager` | Cloudflare API token for DNS-01 |
| `searxng-secret` | `searxng` | secret-key |
| `trek-secret` | `trek` | ENCRYPTION_KEY, ADMIN_EMAIL, ADMIN_PASSWORD |

`make gitops` auto-generates and encrypts all secrets. Requires `GITHUB_TOKEN` + `CLOUDFLARE_TOKEN` in env.

## Services

| Service | URL | Namespace |
|---|---|---|
| Homepage | `home.shublab.com` | `homepage` |
| Grafana | `grafana.shublab.com` | `monitoring` |
| Longhorn | `longhorn.shublab.com` | `longhorn-system` |
| Traefik dashboard | `traefik.shublab.com` | `traefik` |
| Vaultwarden | `vault.shublab.com` | `vaultwarden` |
| SearXNG | `search.shublab.com` | `searxng` |
| Tandoor | `tandoor.shublab.com` | `tandoor` |
| TREK | `trek.shublab.com` | `trek` |

## Key Versions

| Component | Version |
|---|---|
| cilium | 1.17.3 |
| traefik | 32.1.0 |
| cert-manager | v1.17.2 |
| longhorn | 1.7.2 |
| kube-prometheus-stack | 79.* |
| metrics-server | 3.12.2 |
| reloader | 1.2.1 |
| renovate | 45.63.1 |
| reflector | 9.* |
| crowdsec | 0.12.* |
| vaultwarden | 1.2.6 |

## Nodes

| Hostname | Role | IP |
|---|---|---|
| homelab-hpg2-node1 | control-plane | 192.168.0.32 |
| homelab-hpg2-node2 | worker | 192.168.0.33 |
| homelab-hpg2-node3 | worker | 192.168.0.34 |

Traefik LB IP: `192.168.0.2` (Cilium L2 pool: `192.168.0.2/28`)
