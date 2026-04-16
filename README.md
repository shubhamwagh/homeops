# homeops

Bare-metal k3s homelab — from fresh Ubuntu nodes to a fully running cluster with SSO, secrets management, databases, and applications.

## Bootstrap

### 1. Install tools

```sh
brew bundle                          # installs mise, stern, bun, jq, ripgrep, etc.
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc && source ~/.zshrc
mise install                         # installs just, helm, kubectl, yq, gomplate, ansible, k3sup, bun, stern
```

### 2. Provision cluster

```sh
just metal::configure        # interactive: SSH key, node IPs, k3s version
just metal::install          # provision k3s on all nodes
just metal::copy-kubeconfig  # copy kubeconfig to ~/.kube/config
just metal::nodes            # verify all nodes Ready
```

### 3. Install system stack

```sh
just system::install-stack
```

Install order (dependency-driven):

| Step | Component | Why |
|------|-----------|-----|
| 1 | `cilium` | CNI — required by everything |
| 2 | `longhorn` | persistent storage |
| 3 | `cert-manager` | TLS certs + homelab CA |
| 4 | `adguard` | DNS — must exist before gateway |
| 5 | `gateway` | ingress — requires cert-manager + DNS |
| 6 | `vault` | secrets store |
| 7 | `eso` | syncs Vault secrets into k8s |
| 8 | `postgres` | CNPG cluster (needs vault + eso) |
| 9 | `keycloak` | SSO (needs postgres + vault + eso) |
| 10 | `homepage` | dashboard |
| 11 | `skypilot` | ML job scheduler |

> **After `just adguard::install`:** complete the setup wizard at `http://192.168.0.3:3000`, then add DNS rewrite `*.home.didcot → 192.168.0.9` and point your router DNS to `192.168.0.3`.

### 4. Trust the homelab CA

```sh
just cert-manager::trust-ca
source ~/.zshrc
```

### 5. Wire SSO

```sh
just keycloak::setup-vault-oidc          # Vault UI login via Keycloak
just keycloak::setup-k8s-oidc           # kubectl login via Keycloak

just keycloak::create-user homelab <username> <email>
just keycloak::add-user-to-group homelab <username> admins
```

### 6. Install applications

```sh
just tandoor::install
```

---

## Services

| Service | URL |
|---------|-----|
| Homepage | `https://homepage.home.didcot` |
| Vault | `https://vault.home.didcot` |
| Keycloak | `https://keycloak.home.didcot` |
| AdGuard | `https://adguard.home.didcot` |
| Longhorn | `https://longhorn.home.didcot` |
| Hubble | `https://hubble.home.didcot` |
| SkyPilot | `https://skypilot.home.didcot` |
| Tandoor | `https://tandoor.home.didcot` |

---

## Teardown

```sh
just infra::teardown          # removes everything: workloads + Cilium + k3s
```

Or step by step:

```sh
just system::uninstall-stack  # remove all workloads (cluster stays up)
just cilium::uninstall        # remove CNI
just metal::teardown          # wipe k3s from nodes
```

---

## Project Structure

```
homeops/
├── Brewfile                          # brew bundle — bootstrap Mac tooling
├── mise.toml                         # tool version pins (just, helm, kubectl, etc.)
├── Justfile                          # root — imports all modules
├── infrastructure/
│   ├── mod.just                      # infra::install, infra::teardown
│   ├── metal/                        # bare-metal k3s provisioning
│   │   ├── mod.just
│   │   ├── README.md
│   │   ├── inventory.yml.tpl
│   │   ├── group_vars/all.yml.tpl
│   │   └── playbooks/
│   └── system/                       # cluster infrastructure
│       ├── mod.just                  # install-stack / uninstall-stack
│       ├── cilium/
│       ├── longhorn/
│       ├── cert-manager/
│       ├── adguard/
│       ├── gateway/
│       ├── vault/
│       ├── external-secrets/
│       ├── postgresql/
│       ├── keycloak/
│       ├── homepage/
│       ├── skypilot/
└── applications/
    └── tandoor/                      # recipe manager
```

Each component has its own `mod.just` (install/uninstall recipes) and `README.md`.

---

## Useful Commands

```sh
just --list --list-submodules        # all available recipes

just vault::unseal                   # unseal Vault after cluster restart
just vault::token                    # print Vault root token
just vault::get secret/foo/bar       # read a secret
just vault::put secret/foo/bar k=v   # write a secret

just postgres::create-user-db <app>  # create app DB + store creds in Vault
just postgres::psql                  # open psql shell

just eso::status                     # show ClusterSecretStore + all ExternalSecrets
just keycloak::admin-password        # print Keycloak admin password

stern -n <namespace> .               # tail logs for all pods in a namespace
```
