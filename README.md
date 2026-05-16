# homeops

Bare-metal k3s homelab — GitOps with FluxCD, SOPS+age secrets, Cilium CNI+L2LB, Traefik ingress, cert-manager + Let's Encrypt, Longhorn storage, kube-prometheus-stack, and Headscale VPN.

## Architecture

```
                        Internet
                           │
              ┌────────────┴────────────┐
              │    Oracle Free Tier VPS │
              │  headscale.shublab.com  │  ← Tailscale coordination + DERP relay
              │  (141.147.112.251)      │
              └────────────┬────────────┘
                           │  WireGuard VPN (headscale)
         ┌─────────────────┼─────────────────┐
         │                 │                 │
    Mac / iPhone      k3s cluster (LAN: 192.168.0.0/24)
  (100.64.0.x)        node1 (CP)  node2  node3
                      192.168.0.32  .33    .34
                           │
              ┌────────────┴────────────┐
              │  Cilium L2 LB           │
              │  VIP: 192.168.0.2       │  ← Traefik LoadBalancer IP
              │  Wildcard DNS:          │
              │  *.shublab.com → .2     │
              └─────────────────────────┘
```

**Traffic flow (LAN):** `*.shublab.com` → Traefik → in-cluster services

**Traffic flow (remote via VPN):** Mac/iPhone → Headscale VPS → WireGuard → node1 subnet route → 192.168.0.0/24 → services

## Prerequisites

- Ubuntu nodes reachable via SSH (see `infrastructure/metal/README.md`)
- Homebrew installed on control machine
- Domain registered on **Cloudflare** (e.g. `shublab.com`)
- Oracle Free Tier VPS running headscale (see `vps/headscale/README.md`)
- Two env vars set:
  ```bash
  export GITHUB_TOKEN=ghp_xxx        # GitHub PAT with repo scope
  export CLOUDFLARE_TOKEN=cfut_xxx   # Cloudflare API token - Edit zone DNS
  ```

### Cloudflare DNS Setup (one-time)

Add two unproxied A records (orange cloud OFF):

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `*` | `192.168.0.2` | off |
| A | `shublab.com` | `192.168.0.2` | off |
| A | `headscale` | `<oracle-vps-ip>` | off |

The `headscale` record overrides the wildcard so tailscale coordination traffic goes to Oracle VPS, not the cluster.

## Full Setup (fresh nodes → running cluster)

```bash
# 1. Install tools (once)
make tools

# 2. Configure cluster - enter node IPs, SSH key, cluster name
make configure

# 3. Install k3s + Cilium CNI
make bootstrap

# 4. Bootstrap GitOps - generates+encrypts all secrets, bootstraps Flux
GITHUB_TOKEN=xxx CLOUDFLARE_TOKEN=xxx make gitops

# 5. Install Tailscale on all nodes + register with headscale
make tailscale
```

After step 4, Flux reconciles the repo and deploys everything automatically.
Back up `age.agekey` and `.secrets-plaintext` securely, then `rm .secrets-plaintext`.

After step 5, all nodes appear in Headplane at `headplane.shublab.com/admin/`.

## VPN Setup (Headscale on Oracle VPS)

Headscale runs on an Oracle Free Tier VPS for internet/mobile access. See `vps/headscale/` for setup.

```bash
# Deploy headscale to a fresh Ubuntu VPS
cd vps/headscale
ansible-playbook playbooks/install.yml

# Register devices
#   Mac/Linux: tailscale up --login-server=https://headscale.shublab.com --accept-routes
#   iPhone:    Tailscale app → account → use custom login server
```

## Teardown + Rebuild

```bash
make teardown    # wipe k3s + tailscale from all nodes
make bootstrap   # reinstall k3s + cilium
GITHUB_TOKEN=xxx CLOUDFLARE_TOKEN=xxx make gitops
make tailscale   # reinstall tailscale + auto-register all nodes
```

`age.agekey` is preserved across teardown — back it up securely and never lose it.

## Day-to-day

```bash
make flux-status      # show all Flux resources
make flux-sync        # force reconcile from git
make nodes            # kubectl get nodes -o wide
make tailscale        # re-provision tailscale on all nodes
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
| VPN | Tailscale + Headscale | 0.28.0 |

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
| Headplane | `headplane.shublab.com/admin/` | VPN management UI |
| Headscale | `headscale.shublab.com` | VPN coordination (Oracle VPS) |

## Nodes

| Hostname | Role | LAN IP | Tailscale IP |
|---|---|---|---|
| homelab-hpg2-node1 | control-plane | 192.168.0.32 | 100.64.0.x |
| homelab-hpg2-node2 | worker | 192.168.0.33 | 100.64.0.x |
| homelab-hpg2-node3 | worker | 192.168.0.34 | 100.64.0.x |

node1 advertises subnet route `192.168.0.0/24` — remote devices can reach all homelab services via VPN.

## Renovate

Renovate bot runs daily at 2am and opens PRs for outdated Helm chart versions.
Check the Dependency Dashboard issue on GitHub to trigger manual runs or approve updates.
