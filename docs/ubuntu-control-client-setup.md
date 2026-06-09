# Ubuntu Control Client Setup

How to set up a Linux machine as a homeops control client (kubectl, flux, sops, etc.).

Tested on: Ubuntu 22.04/24.04 — machine `192.168.0.52`

---

## Prerequisites

Files that must already exist on the machine (copied from the primary macOS client):

```
~/homeops-secrets/
  age.agekey          # SOPS decryption key
  id_ed25519          # SSH private key for cluster nodes
  id_ed25519.pub      # SSH public key
  inventory.yml       # Ansible inventory (gitignored, machine-specific)
  ssh_config          # SSH aliases for cluster nodes
  groq.json           # Groq AI API credentials
~/.kube/config        # kubeconfig for the k3s cluster
```

---

## Step 1 — System packages

```bash
sudo apt-get update
sudo apt-get install -y curl git jq unzip pipx
```

---

## Step 2 — Install mise

mise manages pinned versions of kubectl, helm, stern, age, sops, ansible, k3sup, yq.

```bash
curl https://mise.run | sh
```

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
eval "$($HOME/.local/bin/mise activate zsh)"
```

Reload shell:

```bash
source ~/.zshrc
```

---

## Step 3 — Clone the repo

```bash
git clone https://github.com/shubhamwagh/homeops.git ~/homeops
```

---

## Step 4 — Install tools via mise

```bash
cd ~/homeops
mise install
```

This installs (versions pinned in `mise.toml`):
- `kubectl`
- `helm`
- `stern`
- `age`
- `sops`
- `yq`
- `ansible` (via pipx)
- `k3sup` (via aqua)

Verify:

```bash
kubectl version --client
helm version
sops --version
age --version
ansible --version
k3sup version
```

---

## Step 5 — Install flux CLI

flux is not in mise.toml. Install via the official script:

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
```

Verify:

```bash
flux version --client
```

---

## Step 6 — SSH config

Link or copy the SSH config so node aliases work:

```bash
mkdir -p ~/.ssh
cp ~/homeops-secrets/ssh_config ~/.ssh/config
cp ~/homeops-secrets/id_ed25519 ~/.ssh/id_ed25519
cp ~/homeops-secrets/id_ed25519.pub ~/.ssh/id_ed25519.pub
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
chmod 600 ~/.ssh/config
```

Test:

```bash
ssh node1 hostname
ssh node2 hostname
ssh node3 hostname
```

---

## Step 7 — SOPS age key

Add to `~/.zshrc`:

```bash
export SOPS_AGE_KEY_FILE=~/homeops-secrets/age.agekey
```

Reload:

```bash
source ~/.zshrc
```

Test decryption (example):

```bash
cd ~/homeops
sops -d infrastructure/base/networking/cloudflared/cloudflare-api-token.sops.yaml
```

---

## Step 8 — kubeconfig

Already present at `~/.kube/config`. Verify cluster access:

```bash
kubectl get nodes -o wide
```

Expected output: node1 (control-plane), node2, node3 all `Ready`.

If the machine is not on the home LAN, connect via Tailscale first (see Step 9).

---

## Step 9 — Tailscale (remote access)

If accessing the cluster from outside the home LAN (`192.168.0.0/24`), install Tailscale and connect to headscale:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Get a pre-auth key from headscale (run on Oracle VPS or via headplane UI at `https://headplane.shublab.com/admin/`):

```bash
# On Oracle VPS (141.147.112.251):
sudo headscale preauthkeys create --user shubham --reusable --expiration 24h
```

Connect (always use `--accept-dns=false` on non-laptop machines to avoid DNS pollution):

```bash
sudo tailscale up \
  --login-server=https://headscale.shublab.com \
  --authkey=<preauth-key> \
  --accept-dns=false \
  --accept-routes=false
```

After connecting, subnet routes via `node1` provide access to `192.168.0.0/24`.

---

## Step 10 — Verify full workflow

```bash
# Cluster nodes
make -C ~/homeops nodes

# Flux status
make -C ~/homeops flux-status

# Force reconcile
make -C ~/homeops flux-sync
```

---

## Groq credentials

Stored at `~/homeops-secrets/groq.json`. Contents:

```json
{
  "provider": "groq",
  "api_key": "<key>",
  "base_url": "https://api.groq.com/openai/v1",
  "model": "groq/llama-3.3-70b-versatile"
}
```

These are used for Tandoor AI recipe import. Configured in Tandoor admin UI at `https://tandoor.shublab.com/admin/` under AI Providers.

---

## Quick reference

| Command | Purpose |
|---|---|
| `kubectl get nodes -o wide` | Check node status |
| `flux get all -A` | Flux reconciliation status |
| `flux reconcile source git flux-system` | Force git sync |
| `stern -n <ns> <pod>` | Tail pod logs |
| `sops -d <file.sops.yaml>` | Decrypt secret |
| `ssh node1` | SSH to control-plane |
