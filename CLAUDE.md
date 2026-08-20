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
make secret APP=<app>   # decrypt one app's human-access credentials (see "Secret Handling")
make secrets-plaintext  # regenerate .secrets-plaintext from secrets-manifest.yaml (generated, not hand-edited)
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
├── secrets-manifest.yaml           # which *.sops.yaml files are human-access vs machine-only
├── scripts/print-secrets.py        # used by `make secret` / `make secrets-plaintext`
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
    │   ├── trek/                   # travel planner (sqlite, own PVC)
    │   ├── better-booking-bot/     # GLL/Better activity booking bot (daemon + web UI, own PVC)
    │   └── hermes-agent/           # self-hosted Hermes Agent, observer-only RBAC, no SSH, own PVC
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
| `better-booking-bot-creds` | `better-booking-bot` | BETTER_USERNAME, BETTER_PASSWORD, CARD_CVV |
| `better-booking-bot-webui-auth` | `better-booking-bot` | htpasswd (Traefik basic auth) |
| `car-health-check-secret` | `car-health-check` | ZYFY_API_KEY, MOT_CLIENT_ID, MOT_CLIENT_SECRET, MOT_API_KEY, MOT_TOKEN_URL, MOT_SCOPE_URL |
| `car-health-check-webui-auth` | `car-health-check` | htpasswd (Traefik basic auth) |
| `hermes-agent-secret` | `hermes-agent` | DASHBOARD_CREDENTIAL (ANTHROPIC_API_KEY / OPENAI_API_KEY not set yet) |
| `hermes-agent-webui-auth` | `hermes-agent` | htpasswd (Traefik basic auth) |

`make gitops` auto-generates and encrypts all secrets. Requires `GITHUB_TOKEN` + `CLOUDFLARE_TOKEN` in env.

## Secret Handling

Two independent axes classify every credential in this repo - both matter, don't conflate them.

**MACHINE-ONLY vs HUMAN-ACCESS** - who needs the value:
- *Machine-only*: consumed only by a pod/service (DB passwords, API tokens, app internal secret keys). No routine reason a human ever reads these. `sops -d` directly if you genuinely need to.
- *Human-access*: a person types this into a login or basic-auth prompt (dashboard admin passwords, Traefik/Longhorn basic-auth). These are the only ones surfaced by `make secret` / `make secrets-plaintext`.

Which files are which is declared in `secrets-manifest.yaml` (repo root, not gitignored, contains no secret values - just pointers). Add new entries there whenever a new credential is created.

**Recoverable vs hash-only** - whether git can ever reproduce the plaintext:
- *Recoverable* (`recoverable: true` in the manifest): the SOPS file stores the literal value in `stringData` - `sops -d` always gets it back. True second-source-of-truth risk is zero here; `.secrets-plaintext` is purely a convenience cache.
- *Hash-only* (`recoverable: false`): the file stores a one-way htpasswd/bcrypt/apr1 hash (Traefik `basicAuth` needs a hash, not a password). The plaintext existed only for one moment - when the credential was created - and is gone forever afterward unless it was captured somewhere durable then. **This is the only place a plaintext store (`.secrets-plaintext` today, Vaultwarden eventually) is not redundant** - for these specific entries it is the sole record, not a convenience copy.

**Workflow:**
- `make secret APP=<app>` - decrypt and print just one app's human-access credentials.
- `make secrets-plaintext` - regenerate the full local dump from `secrets-manifest.yaml` + the SOPS files. **This file is generated, never hand-edited** - if a value is missing from it, fix `secrets-manifest.yaml`, don't paste values in by hand. `.secrets-plaintext` stays gitignored; back it up (eventually to Vaultwarden - already deployed at `vault.shublab.com`, not yet wired into this workflow) and delete it when done, per the file's own header.
- Whenever a **new** credential is created - by a human, by `make secrets`, or by an agent - and it's going to be stored as a hash (htpasswd, etc.), capture the plaintext into `.secrets-plaintext`/Vaultwarden **at that moment**. There is no later chance.

**Letting agents (Hermes, etc.) create new credentials without ever seeing decryption:**
SOPS encryption only requires the age **public recipient** - never the private key (`age.agekey`). The recipient (`age1nhpn7w8hv4x7lfwc7a8r4ycwvcqn6tz6tekhnlahc67l7ngt8y5qdqhxsr`) is not secret - it's already committed in plaintext in `.sops.yaml` and in every `*.sops.yaml` file's own `sops.age[].recipient` field. Hermes gets this value via the non-secret `sops-age-recipient` ConfigMap in its own namespace (readable under its existing observer RBAC - `configmaps` get/list/watch - no permission change needed). To create a new secret it should:
1. Generate the plaintext value itself (never ask a human for one to relay through it).
2. Immediately run `sops --encrypt --age "$(cat recipient)" <plaintext-manifest.yaml>` (fetching the `sops`/`age` static binaries into its own workspace if not already present - no root needed, they're plain Go binaries).
3. Return **only** the encrypted output in its response - never echo the plaintext back, never write it to `/opt/data/memories` or anywhere else persistent.
4. A human copies the encrypted file into the repo, adds it to `secrets-manifest.yaml`, reviews, commits and pushes. Hermes has no git write access in this phase - that boundary is deliberate (see the hermes-agent app's own docs / ClusterRole).

**Never expose plaintext in**: CI logs (the `ci.yml` SOPS check only greps for `ENC[`, never decrypts), Hermes's own chat output for anything beyond the single moment described above, Git (enforced by the CI check), or persistent agent memory (Claude's own memory files and Hermes's `/opt/data/memories` should only ever contain pointers like "see `.secrets-plaintext`" or "see Vaultwarden", never a value).

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
| Better Booking Bot | `booking-bot.shublab.com` | `better-booking-bot` |
| Car Health Check | `carhealth.shublab.com` | `car-health-check` |
| Hermes Agent | `hermes.shublab.com` | `hermes-agent` |

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
