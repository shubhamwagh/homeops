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
make secrets-plaintext  # regenerate .secrets-plaintext (human-access creds) from secrets-manifest.yaml
make secrets-plaintext-machine  # regenerate .secrets-plaintext-machine (raw machine-only dump, reference/backup only)
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
| `github-app-private-key` | `github-token-broker` | GitHub App PEM for `Hermes Blog Reviewer` (App 4669702, `shubhamwagh/blog` only) - never read by Hermes |
| `hermes-agent-webui-auth` | `hermes-agent` | htpasswd (Traefik basic auth) |

`make gitops` auto-generates and encrypts all secrets. Requires `GITHUB_TOKEN` + `CLOUDFLARE_TOKEN` in env.

## Secret Handling

Two independent axes classify every credential in this repo - both matter, don't conflate them.

**MACHINE-ONLY vs HUMAN-ACCESS** - who needs the value:
- *Machine-only*: consumed only by a pod/service (DB passwords, API tokens, app internal secret keys). No routine reason a human ever reads these. `sops -d` directly if you genuinely need to.
- *Human-access*: a person types this into a login or basic-auth prompt (dashboard admin passwords, Traefik/Longhorn basic-auth). These are the only ones surfaced by `make secret` / `make secrets-plaintext`.
- *Machine-only* secrets are still fully recoverable in git (all plain `stringData`) - they're just kept out of the human-access dump by default since there's no routine reason to see a GitHub PAT while logging into Grafana. `make secrets-plaintext-machine` regenerates a **separate** raw dump of every machine-only field (backwards-compatible reference/backup - not a login credential), kept in its own gitignored file, never merged into `.secrets-plaintext`.

Which files are which is declared in `secrets-manifest.yaml` (repo root, not gitignored, contains no secret values - just pointers). Add new entries there whenever a new credential is created.

**Recoverable vs hash-only** - whether git can ever reproduce the plaintext:
- *Recoverable* (`recoverable: true` in the manifest): the SOPS file stores the literal value in `stringData` - `sops -d` always gets it back. True second-source-of-truth risk is zero here; `.secrets-plaintext` is purely a convenience cache.
- *Hash-only* (`recoverable: false`): the file stores a one-way htpasswd/bcrypt/apr1 hash (Traefik `basicAuth` needs a hash, not a password). The plaintext existed only for one moment - when the credential was created - and is gone forever afterward unless it was captured somewhere durable then. **This is the only place a plaintext store (`.secrets-plaintext` today, Vaultwarden eventually) is not redundant** - for these specific entries it is the sole record, not a convenience copy.

**Workflow:**
- `make secret APP=<app>` - decrypt and print just one app's human-access credentials.
- `make secrets-plaintext` - regenerate the full local dump from `secrets-manifest.yaml` + the SOPS files. **This file is generated, never hand-edited** - if a value is missing from it, fix `secrets-manifest.yaml`, don't paste values in by hand. `.secrets-plaintext` stays gitignored; back it up (eventually to Vaultwarden - already deployed at `vault.shublab.com`, not yet wired into this workflow) and delete it when done, per the file's own header.
- Whenever a **new** credential is created - by a human, by `make secrets`, or by an agent - and it's going to be stored as a hash (htpasswd, etc.), capture the plaintext into `.secrets-plaintext`/Vaultwarden **at that moment**. There is no later chance.

**Letting agents (Hermes, etc.) create new credentials without ever seeing decryption:**
SOPS encryption only requires the age **public recipient** - never the private key (`age.agekey`). The recipient (`age1nhpn7w8hv4x7lfwc7a8r4ycwvcqn6tz6tekhnlahc67l7ngt8y5qdqhxsr`) is not secret - it's already committed in plaintext in `.sops.yaml` and in every `*.sops.yaml` file's own `sops.age[].recipient` field. Hermes gets this value via the non-secret `sops-age-recipient` ConfigMap in its own namespace (readable under `hermes-operator`'s `configmaps` access - no permission change needed). To create a new secret it should:
1. Generate the plaintext value itself (never ask a human for one to relay through it).
2. Immediately run `sops --encrypt --age "$(cat recipient)" <plaintext-manifest.yaml>` (fetching the `sops`/`age` static binaries into its own workspace if not already present - no root needed, they're plain Go binaries).
3. Return **only** the encrypted output in its response - never echo the plaintext back, never write it to `/opt/data/memories` or anywhere else persistent.
4. The encrypted file gets added to the repo and `secrets-manifest.yaml`. Whether Hermes commits/pushes this itself or a human does depends on the git-write-access decision in "Hermes Autonomy Policy" below - as of this writing Hermes still has no git credentials, so a human does step 4 regardless of RBAC tier.

**Never expose plaintext in**: CI logs (the `ci.yml` SOPS check only greps for `ENC[`, never decrypts), Hermes's own chat output for anything beyond the single moment described above, Git (enforced by the CI check), or persistent agent memory (Claude's own memory files and Hermes's `/opt/data/memories` should only ever contain pointers like "see `.secrets-plaintext`" or "see Vaultwarden", never a value).

## Hermes Autonomy Policy

Hermes operates as **autonomous unless critical** - a trusted operator, not a read-only advisor. Every action is classified GREEN (autonomous), YELLOW (autonomous, higher caution), or RED (explicit approval required, before execution). Full classification and the required RED presentation format (ACTION/WHY/EXPECTED IMPACT/BLAST RADIUS/BACKUP-RECOVERY/ROLLBACK/ALTERNATIVES, then "Do you approve this critical operation?") live in Hermes's own `SOUL.md` (`/opt/data/SOUL.md` on its PVC - not git-managed, Hermes maintains it itself; ask Hermes directly to see or update its current policy).

**RBAC design - four ClusterRoles, only one bound cluster-wide:**

- **`hermes-operator-read`** (`clusterrole.yaml` + `clusterrolebinding.yaml`, cluster-wide via ClusterRoleBinding) - get/list/watch (get/list for `metrics.k8s.io`, which has no watch) on everything Hermes can see: nodes, namespaces, events, PVC/PV, Pods/logs, Services, ConfigMaps, Endpoints, Deployments/StatefulSets/DaemonSets/ReplicaSets, Jobs/CronJobs, Ingresses/IngressClasses/NetworkPolicies, HPAs, StorageClasses/CSI resources, Flux Kustomization/HelmRelease/GitRepository/HelmRepository/HelmChart, Longhorn, Cilium, Traefik CRDs, cert-manager. **Read-only, no exceptions** - this is the only role bound cluster-wide.
- **`hermes-operator-write`** (`clusterrole-write.yaml`) - create/update/patch/delete on ordinary workload resources (Pods delete-only, Services/ConfigMaps/Deployments/StatefulSets/DaemonSets/Jobs/CronJobs/Ingresses/HPAs full write, ReplicaSets patch/delete, `/scale` subresources). **Defined once as a ClusterRole but never bound via a ClusterRoleBinding** - only takes effect where a RoleBinding names it, which today is `rolebindings-write.yaml`: exactly the 8 `apps/base/*` namespaces (better-booking-bot, blog, car-health-check, hermes-agent, homepage, ntfy, tandoor, trek). A new app under `apps/base/` needs a matching entry there before Hermes gets write access to it - not automatic.
- **`hermes-operator-flux-reconcile`** (`clusterrole-flux-reconcile.yaml`) - `patch` only, on `Kustomization`/`HelmRelease` - nothing else in those namespaces is touched, no pod/deployment/configmap write comes with this. **Honest characterisation: this is Flux object mutation, not "reconcile-only."** RBAC has no way to restrict a `patch` verb to a single field or annotation - it grants patch on the whole object. In practice this means Hermes could, with this permission alone, also change a `HelmRelease`'s chart version/values or a `Kustomization`'s source ref/path/prune settings, not just trigger a reconcile or toggle `spec.suspend`. That's being consciously accepted as a YELLOW-tier capability in service of the autonomy goal, not because it's technically narrower than it sounds - if reconcile-only enforcement is ever wanted for real, that requires a CEL-based guard (like `admission-secret-guard.yaml` below) restricting *which* fields a patch may touch, not a coarser RBAC role. Not built now - noted as a deliberate gap. Bound via `rolebindings-flux-reconcile.yaml` in `flux-system` (the 4 Kustomizations) plus `cert-manager`/`cnpg-system`/`crowdsec`/`kube-system`/`longhorn-system`/`monitoring`/`reflector`/`reloader`/`renovate`/`traefik`/`vaultwarden` (one `HelmRelease` each, per `flux get helmreleases -A` - HelmReleases live beside the release they manage, not centralised in `flux-system`).
- **`hermes-critical-operator`** (`clusterrole-critical.yaml`, exists but never bound by default) - the RED-tier permissions, unchanged by this redesign: delete PVC/PV/Longhorn volumes-replicas-backups-snapshots, delete Namespaces, delete CRDs, write ClusterRoles/ClusterRoleBindings/ServiceAccounts, node drain. Still excludes Secrets entirely, even elevated.

**Namespace risk tiers**: the 8 `apps/base/*` namespaces (better-booking-bot, blog, car-health-check, hermes-agent, homepage, ntfy, tandoor, trek) are the explicitly reviewed, currently-ordinary namespaces that get `hermes-operator-write`. **This is not a permanent rule that "everything under `apps/base/` is automatically ordinary"** - it's the record of eight namespaces that have actually been classified. Every other current namespace - `cert-manager`, `cilium-secrets`, `cloudflared`, `cnpg-system`, `crowdsec`, `default`, `flux-system`, `headscale`, `kube-node-lease`, `kube-public`, `kube-system`, `longhorn-system`, `monitoring`, `postgres`, `reflector`, `reloader`, `renovate`, `searxng`, `traefik`, `vaultwarden` - gets zero write access from `hermes-operator-write`, only the narrow Flux-reconcile exception where it actually holds a `HelmRelease`. `searxng` and `renovate` are deliberately kept in the protected tier for now despite being fairly low-blast-radius (they happen to live under `infrastructure/` in this repo, but that folder location is not the actual classification criterion, just a proxy that was used for a first pass) - revisit explicitly if that turns out to be too conservative. **Any new namespace - including a new one added under `apps/base/`- must be explicitly classified and given its own `rolebindings-write.yaml` entry before it gets `hermes-operator-write`. Nothing about the directory it lives in grants that automatically.** A future database-critical app landing under `apps/base/` should not silently inherit ordinary-tier write access just from its location.

**Exact node RBAC** (part of `hermes-critical-operator`, elevation-gated): documented as "node drain" earlier, but the actual grant is broader than that phrase implies and should be read as such:
- `update`/`patch` verbs on the core `Node` object - RBAC cannot restrict *which* field of the Node spec gets changed. This covers cordon (`.spec.unschedulable`) but equally covers `.spec.taints` and any other writable Node spec field. **Read this as "general Node-object mutation," not "cordon-only."** That's accepted because it's already behind explicit break-glass elevation, not because taint modification is technically unavailable.
- `create` on the `pods/eviction` subresource (the Eviction API) for each pod on that node - this is also where PodDisruptionBudgets get enforced, server-side, by the API server processing the Eviction request, regardless of the caller's RBAC.
- Reading which pods are on the node uses the already cluster-wide `pods: get/list` from `hermes-operator-read`.
- Does **not** include: node deletion, or any `nodes/proxy` access. Neither is granted anywhere.

**Secret-boundary admission guardrail** (`admission-secret-guard.yaml`, DRAFT - not yet applied): RBAC alone leaves a real gap here. Hermes has no `get secrets` anywhere, but `hermes-operator-write`'s Deployment/StatefulSet/DaemonSet/ReplicaSet/Job/CronJob write, combined with `pods/log` read (`hermes-operator-read`), means Hermes could in principle patch a workload to add a `secretKeyRef` env var and then read the secret's value back out via `kubectl logs` - or create a brand-new workload that mounts an existing Secret. Write access to workloads in a namespace is close to equivalent to access to whatever Secrets those workloads can already reference - a general Kubernetes property, not specific to this design.

Two `ValidatingAdmissionPolicy` + `ValidatingAdmissionPolicyBinding` pairs implement this, scoped via `matchConditions` to `request.userInfo.username == "system:serviceaccount:hermes-agent:hermes-homelab"` only (Flux and every other identity are completely unaffected - Flux can still deploy workloads with legitimate Secret references via normal GitOps). One targets Deployment/StatefulSet/DaemonSet/ReplicaSet/Job (pod template at `.spec.template.spec`), the other CronJob (`.spec.jobTemplate.spec.template.spec`). Rule: a create/update from that identity is denied if it introduces or changes an `env[].valueFrom.secretKeyRef`, `envFrom[].secretRef`, a Secret volume, or `imagePullSecrets` - an *unchanged* existing reference is always allowed, which is what keeps already-secret-using apps (car-health-check, better-booking-bot) still routinely patchable. Also denied: introducing/changing `serviceAccountName`, privileged containers, added Linux capabilities, hostPath volumes, or hostNetwork/hostPID/hostIPC. On CREATE, `oldObject` is null, so nothing can match as "already existed" - a brand-new workload from Hermes cannot carry any Secret reference at all.

**This narrows the gap, it does not close it - the accurate threat model matters here.** The admission policy stops Hermes from *introducing or changing* a Secret reference. It does not, and structurally cannot, stop Hermes from exploiting a Secret reference a workload *already has*. If an existing Deployment already has `env: DB_PASSWORD valueFrom.secretKeyRef`, that reference is unchanged and therefore allowed to persist - but Hermes can still patch that same Deployment's container `command`/`args` to print `$DB_PASSWORD`, then read it back via `pods/log` (already granted). The same applies to an existing Secret volume: the volume reference itself can't be added or changed, but a sufficiently broad pod-template edit can still expose what's already mounted. This is not a bug in the policy - it is a general Kubernetes property: **broad workload-admin rights over a namespace where workloads consume Secrets, combined with log read access, is close to equivalent to access to those Secrets.** Do not describe this as "Hermes technically cannot access any Kubernetes Secret." The accurate statement is:

> Hermes has no Kubernetes Secret API access and cannot access Secrets in protected namespaces. In ordinary writable application namespaces, workload-admin authority may indirectly expose credentials already available to those workloads - accepted as part of Hermes acting as the de facto administrator of those applications.

Namespace separation is what makes this an acceptable tradeoff rather than an open one:
- **Ordinary apps** (the 8 `apps/base/*` namespaces): Hermes has workload-admin authority → app-level Secret exposure is theoretically possible → accepted, since Hermes is effectively administering those applications anyway.
- **Protected infrastructure** (everything else): Hermes is read-only → it cannot mutate a workload to expose what it consumes → this tier keeps the *stronger* technical isolation the RBAC redesign was for.
- **AGE private key**: unavailable everywhere, no exception.
- **Vaultwarden**: unavailable everywhere, no exception.

The credentials that actually matter most - the ones that would compromise the whole encrypt-at-rest model or the human credential store - stay outside Hermes's reach entirely, regardless of namespace tier.

CEL compiles successfully (verified via `kubectl apply --dry-run=server`) and has been exercised against a real test matrix (below) before enforcement was turned on. Applied with `validationActions: [Deny, Audit]` (see test matrix results below for what justified moving off `[Warn, Audit]`).

Also confirmed absent from every role (`hermes-operator-read`, `hermes-operator-write`, `hermes-operator-flux-reconcile`, `hermes-critical-operator`): `pods/exec`, `pods/attach`, `pods/portforward`, `pods/ephemeralcontainers`, `serviceaccounts/token`. None of these are granted anywhere, unconditionally.

**Future issue, not yet relevant (Hermes has no git credentials): this admission policy is identity-scoped and does not follow through Git.** Once Hermes can push to HomeOps, a dangerous manifest merged via Git is applied by *Flux's* controller identity, not `system:serviceaccount:hermes-agent:hermes-homelab` - the `matchConditions` username check would not fire, since the API server sees the request as coming from Flux. Live admission scoped to Hermes's identity and GitOps-path trust are two different boundaries; solving the first does not solve the second. Before Hermes gets git write access, that path needs its own control - "Step 0.5: GitOps authority control" - likely a Hermes-scoped GitHub App → feature branch → PR → CI policy validation → auto-merge for ordinary changes / Shubham review for critical paths (CODEOWNERS on cluster RBAC, Flux bootstrap, Longhorn, Cilium, cert-manager, critical storage, SOPS infrastructure, and Hermes's own privilege configuration) - the same GREEN/YELLOW/RED model, applied to the Git path instead of the live Kubernetes path. Not designed in detail yet; noted here so it isn't forgotten when git write access is revisited.

**Break-glass elevation** (`elevation-revoker.yaml` + `break-glass/*.tmpl` + Makefile, unchanged by this redesign): Hermes cannot elevate itself - it holds no permission over ClusterRoleBindings at all. After Shubham approves a RED action, *he* runs `make hermes-elevate REASON="..." [TTL_MINUTES=15]` on his own machine, which `kubectl apply`s a `hermes-critical-operator-elevated` ClusterRoleBinding (outside Flux entirely - never listed in any kustomization, so `prune: true` never touches it) plus a Job that self-revokes it after the TTL, using a narrowly-scoped `hermes-elevation-revoker` identity that can only `get`/`delete` that one specifically-named binding. `make hermes-elevate-status` checks whether elevation is currently active; `make hermes-revoke` ends it immediately. This is the "safest practical mechanism" tradeoff: short-lived, auditable (`kubectl get clusterrolebinding`/`kubectl get jobs -n hermes-agent`), and structurally impossible for Hermes to trigger on its own.

**Git write access - proposed, not provisioned:** the policy calls for Hermes to eventually "commit normal HomeOps changes" and "push... when part of a task Shubham explicitly asked for." This needs real GitHub credentials in Hermes's pod, which is a bigger risk than any RBAC tier above - once something lands on `main`, Flux applies it with `prune: true` using its own privileged `sops-age` identity, which can do far more than any role documented here. RBAC scoping means nothing if the same outcome is reachable by pushing a manifest instead of calling the API directly.

Recommended mechanism, in preference order:
1. **GitHub App**, installed only on `shubhamwagh/homeops`, with the narrowest permission set that works (`contents: write`, `pull_requests: write` if using a PR flow, nothing else - no org-wide or account-wide scope). App installation tokens are short-lived (~1 hour) and auto-scoped to just the repos the App is installed on - Hermes would fetch a fresh token per session rather than holding one long-lived credential. This is the GitHub-native equivalent of a scoped, auditable, revocable-per-installation identity.
2. Fallback: a **fine-grained personal access token**, scoped to only `shubhamwagh/homeops`, `contents: write` only, with an expiration date - strictly worse than a GitHub App (still a static bearer credential, no automatic rotation) but far narrower than a classic PAT or Shubham's own broad credential.
3. Never: Shubham's own personal GitHub credential, a classic PAT, or any org/account-wide token.

Recommended workflow once provisioned: Hermes pushes to a branch and opens a PR rather than pushing directly to `main`, at least until the autonomy model has run long enough to trust unattended direct pushes - matching the same "prove it, then loosen it" pattern used for the RBAC tiers above. **Not implemented for homeops itself** - no App, token, or credential exists yet for the homeops repo. A separate, narrower integration for a *different* repo does exist - see below.

## GitHub App Token Broker (`shubhamwagh/blog` only, live)

Hermes has one scoped credential path today, to `shubhamwagh/blog`, via a dedicated GitHub App (`Hermes Blog Reviewer`, App ID `4669702`) - **not** the homeops App discussed above, which remains unprovisioned. **This is a reviewer identity, not an authoring one** - confirmed live via `GET /installation/repositories` on a real minted token, which returned `"push": false`. The App holds `pull_requests: write` + `checks: read` only, no `contents` permission at all. It exists to let Hermes approve/comment on a blog PR under a genuinely separate GitHub identity from whoever authored it (solving the self-review problem - the same account approving its own PR isn't a real four-eyes gate) - it cannot clone, commit, or push. Authoring/publishing a post still needs a different, unprovisioned credential; see the `homelab-blog-authoring` and `hermes-blog-reviewer` skills (Hermes's own PVC) for the full division of responsibility. This is a completely separate credential from anything else in this repo, on purpose - a compromised or misused review token has no path to homeops or to writing blog content.

Hermes never holds the App's private key. Architecture:

```
Hermes (its own projected K8s SA token)
       │ POST http://github-token-broker.github-token-broker.svc.cluster.local/v1/token
       │ Authorization: Bearer <SA token>
       ▼
github-token-broker (infrastructure/base/github-token-broker/, own namespace)
       │ 1. TokenReview the SA token against the K8s API - reject unless it's
       │    exactly system:serviceaccount:hermes-agent:hermes-homelab
       │ 2. Sign a GitHub App JWT with the mounted private key (never returned/logged)
       │ 3. GET /repos/shubhamwagh/blog/installation - discovers the installation live
       │ 4. POST /app/installations/{id}/access_tokens
       ▼
{ "token": "ghs_...", "expires_at": "...", "repository": "shubhamwagh/blog" }
```

Key properties:
- **Deliberately under `infrastructure/base/`, not `apps/base/`** - the same mechanism that keeps `hermes-operator-write` scoped to the 8 ordinary namespaces also means this namespace never gets a write RoleBinding automatically. Hermes can see the broker exists (cluster-wide read) but cannot modify its Deployment or read its Secret - Secrets are excluded from every Hermes role regardless.
- **No shared secret** between Hermes and the broker - the broker authenticates callers using their own Kubernetes identity via `TokenReview`, so there's nothing extra to provision, rotate, or leak on the calling side.
- **CiliumNetworkPolicy** (`networkpolicy.yaml`) restricts inbound connections to the broker's port to the `hermes-agent` namespace only - defense in depth alongside the TokenReview check.
- **The broker's own RBAC is one verb**: `create` on `tokenreviews.authentication.k8s.io`, cluster-scoped, nothing else. It doesn't need permission to read its own mounted Secret - that's a kubelet-managed volume mount, not an RBAC-gated API read.
- **Nothing persisted**: tokens are minted fresh per request, never cached, never logged. Only `expires_at` and the calling identity are logged.
- Source: [`shubhamwagh/github-app-token-broker`](https://github.com/shubhamwagh/github-app-token-broker) - stdlib HTTP server + exactly one third-party dependency (`cryptography`, for RSA-SHA256 JWT signing), kept intentionally small enough to read in one sitting since it's the one place a real long-lived credential lives.
- **Deployment model is one broker instance per `(App, repo)` pair, never multi-tenant** - a future homeops App, or any other future integration, gets its own namespace/Secret/NetworkPolicy/instance of the same image, not a shared credential store. See the broker repo's own README for the reasoning.

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
| IT-Tools | `it-tools.shublab.com` | `it-tools` |
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
