ANSIBLE    := $(HOME)/.local/share/mise/installs/pipx-ansible/latest/ansible/bin/ansible-playbook
METAL_DIR  := infrastructure/metal
INVENTORY  := $(METAL_DIR)/inventory.yml
VARS_FILE  := $(METAL_DIR)/group_vars/all.yml
PLAYBOOKS  := $(METAL_DIR)/playbooks

GITHUB_USER ?= shubhamwagh
GITHUB_REPO ?= homeops

.PHONY: tools configure install add-node teardown nodes copy-kubeconfig \
        bootstrap cilium-bootstrap ensure-age-key secrets gitops \
        flux-create-sops-secret flux-bootstrap flux-status flux-sync

# ─── tooling ───────────────────────────────────────────────────────────────

tools:
	brew bundle
	mise install

# ─── cluster provisioning ──────────────────────────────────────────────────

configure:
	@mkdir -p $(METAL_DIR)/group_vars
	@if [ -f $(INVENTORY) ]; then echo "$(INVENTORY) already exists — delete and re-run to reconfigure"; exit 0; fi; \
	 read -rp "SSH user [ubuntu]: " SSH_USER; SSH_USER=$${SSH_USER:-ubuntu}; \
	 read -rp "SSH key path [~/.ssh/id_ed25519]: " SSH_KEY; SSH_KEY=$${SSH_KEY:-~/.ssh/id_ed25519}; \
	 read -rp "Control-plane IPs (space-separated): " CP_NODES; \
	 read -rp "Worker IPs (space-separated, or blank): " WRK_NODES; \
	 read -rp "Cluster name [homelab-cluster]: " CLUSTER_NAME; CLUSTER_NAME=$${CLUSTER_NAME:-homelab-cluster}; \
	 read -rsp "k3s token (blank = auto-generate): " K3S_TOKEN; echo; \
	 [ -z "$$K3S_TOKEN" ] && K3S_TOKEN=$$(openssl rand -hex 16); \
	 { \
	   echo "all:"; echo "  children:"; echo "    control_plane:"; echo "      hosts:"; \
	   for ip in $$CP_NODES; do echo "        $$ip:"; echo "          ansible_user: $$SSH_USER"; echo "          ansible_ssh_private_key_file: $$SSH_KEY"; done; \
	   if [ -n "$$WRK_NODES" ]; then \
	     echo "    workers:"; echo "      hosts:"; \
	     for ip in $$WRK_NODES; do echo "        $$ip:"; echo "          ansible_user: $$SSH_USER"; echo "          ansible_ssh_private_key_file: $$SSH_KEY"; done; \
	   fi; \
	 } > $(INVENTORY); chmod 600 $(INVENTORY); echo "wrote $(INVENTORY)"; \
	 { \
	   echo "cluster_name: \"$$CLUSTER_NAME\""; \
	   echo "k3s_token: \"$$K3S_TOKEN\""; \
	   echo "k3s_version: \"\""; \
	   echo "control_plane_vip: \"\""; \
	   echo "extra_server_args: \"--write-kubeconfig-mode=644 --disable=flannel,local-storage,metrics-server,servicelb,traefik --flannel-backend=none --disable-network-policy --disable-cloud-controller --disable-kube-proxy\""; \
	   echo "extra_agent_args: \"\""; \
	   echo "kubeconfig_output: \"$$HOME/.kube/config\""; \
	 } > $(VARS_FILE); chmod 600 $(VARS_FILE); echo "wrote $(VARS_FILE)"

# k3s install + copy kubeconfig + cilium — run once on fresh cluster
bootstrap: install copy-kubeconfig cilium-bootstrap

install: $(INVENTORY)
	$(ANSIBLE) -i $(INVENTORY) $(PLAYBOOKS)/install.yml

add-node: $(INVENTORY)
	$(ANSIBLE) -i $(INVENTORY) $(PLAYBOOKS)/add-node.yml

teardown: $(INVENTORY)
	$(ANSIBLE) -i $(INVENTORY) $(PLAYBOOKS)/teardown.yml
	rm -f .secrets-plaintext
	@echo "Cluster torn down. age.agekey kept — back it up to 1Password."

nodes:
	kubectl get nodes -o wide

copy-kubeconfig: $(INVENTORY)
	@init_node=$$(yq '.all.children.control_plane.hosts | keys | .[0]' $(INVENTORY)); \
	 ssh_user=$$(yq '.all.children.control_plane.hosts | to_entries | .[0].value.ansible_user' $(INVENTORY)); \
	 mkdir -p $$HOME/.kube; \
	 ssh -t "$$ssh_user@$$init_node" "sudo cat /etc/rancher/k3s/k3s.yaml" \
	   | sed "s/127.0.0.1/$$init_node/g" > $$HOME/.kube/config; \
	 chmod 600 $$HOME/.kube/config; \
	 echo "kubeconfig written to ~/.kube/config"

cilium-bootstrap:
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium \
	  --version 1.17.3 --namespace kube-system \
	  --set k8sServiceHost=10.43.0.1 \
	  --set k8sServicePort=443 \
	  --set kubeProxyReplacement=true \
	  --set bpf.masquerade=true \
	  --set cgroup.autoMount.enabled=false \
	  --set cgroup.hostRoot=/sys/fs/cgroup \
	  --set ipam.mode=kubernetes \
	  --set l2announcements.enabled=true \
	  --set externalIPs.enabled=true \
	  --set operator.replicas=1 \
	  --wait --timeout=5m

$(INVENTORY):
	$(error inventory not found — run: make configure)

# ─── gitops bootstrap (run once after cluster is up) ───────────────────────

# Auto-generate age key if missing and update .sops.yaml
ensure-age-key:
	@if [ ! -f age.agekey ]; then \
	  echo "Generating new age key..."; \
	  age-keygen -o age.agekey; \
	  PUB_KEY=$$(grep "public key" age.agekey | awk '{print $$NF}'); \
	  sed -i '' "s/age1[a-z0-9]*$$/$$PUB_KEY/" .sops.yaml; \
	  echo "Updated .sops.yaml with new public key: $$PUB_KEY"; \
	else \
	  echo "age.agekey exists — reusing existing key"; \
	fi

# Generate + encrypt all secrets (grafana, tandoor, renovate GitHub token)
secrets: ensure-age-key
	@test -n "$(GITHUB_TOKEN)"    || (echo "GITHUB_TOKEN not set"    && exit 1)
	@test -n "$(CLOUDFLARE_TOKEN)" || (echo "CLOUDFLARE_TOKEN not set" && exit 1)
	@echo "Generating and encrypting secrets..."
	@GRAFANA_PASS=$$(openssl rand -base64 24); \
	 TANDOOR_KEY=$$(openssl rand -base64 48); \
	 TANDOOR_DB_PASS=$$(openssl rand -base64 24); \
	 SEARXNG_SECRET=$$(openssl rand -hex 32); \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin-secret\n  namespace: monitoring\nstringData:\n  admin-password: "%s"\n' \
	   "$$GRAFANA_PASS" > infrastructure/base/monitoring/kube-prometheus-stack/secret-grafana-admin.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: tandoor-secret\n  namespace: tandoor\nstringData:\n  SECRET_KEY: "%s"\n  POSTGRES_PASSWORD: "%s"\n' \
	   "$$TANDOOR_KEY" "$$TANDOOR_DB_PASS" > apps/base/tandoor/secret.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: renovate-github-token\n  namespace: renovate\nstringData:\n  RENOVATE_TOKEN: "%s"\n' \
	   "$(GITHUB_TOKEN)" > infrastructure/base/controllers/renovate/secret.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-api-token\n  namespace: cert-manager\nstringData:\n  api-token: "%s"\n' \
	   "$(CLOUDFLARE_TOKEN)" > infrastructure/base/networking/cert-manager/secret-cloudflare.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: searxng-secret\n  namespace: searxng\nstringData:\n  secret-key: "%s"\n' \
	   "$$SEARXNG_SECRET" > infrastructure/base/searxng/secret.sops.yaml; \
	 sops --encrypt --in-place infrastructure/base/monitoring/kube-prometheus-stack/secret-grafana-admin.sops.yaml; \
	 sops --encrypt --in-place apps/base/tandoor/secret.sops.yaml; \
	 sops --encrypt --in-place infrastructure/base/controllers/renovate/secret.sops.yaml; \
	 sops --encrypt --in-place infrastructure/base/networking/cert-manager/secret-cloudflare.sops.yaml; \
	 sops --encrypt --in-place infrastructure/base/searxng/secret.sops.yaml; \
	 printf '# Back these up securely then delete this file\ngrafana:          %s\ntandoor-key:      %s\ntandoor-db:       %s\nsearxng-secret:   %s\n' \
	   "$$GRAFANA_PASS" "$$TANDOOR_KEY" "$$TANDOOR_DB_PASS" "$$SEARXNG_SECRET" > .secrets-plaintext; \
	 echo "All secrets encrypted. Plaintext saved to .secrets-plaintext"

# Commit updated .sops.yaml + encrypted secrets and push to git
flux-commit-secrets:
	@git add .sops.yaml infrastructure/ apps/
	@git diff --cached --quiet && echo "No secret changes to commit" || \
	  (git commit -m "chore: rotate encrypted secrets" && git push)

flux-create-sops-secret:
	kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic sops-age \
	  --namespace=flux-system \
	  --from-file=age.agekey \
	  --dry-run=client -o yaml | kubectl apply -f -

flux-bootstrap:
	@test -n "$(GITHUB_TOKEN)" || (echo "GITHUB_TOKEN not set" && exit 1)
	flux bootstrap github \
	  --owner=$(GITHUB_USER) \
	  --repository=$(GITHUB_REPO) \
	  --branch=main \
	  --path=clusters/staging \
	  --personal \
	  --token-auth

# Single command: age key → secrets → commit → sops secret → flux bootstrap
# Usage: GITHUB_TOKEN=xxx CLOUDFLARE_TOKEN=xxx make gitops
gitops: secrets flux-commit-secrets flux-create-sops-secret flux-bootstrap
	@echo ""
	@echo "GitOps bootstrapped. Check status: make flux-status"
	@echo "Save .secrets-plaintext to 1Password, then: rm .secrets-plaintext"

# ─── day-to-day ops ────────────────────────────────────────────────────────

flux-status:
	flux get all -A

flux-sync:
	flux reconcile source git flux-system
	flux reconcile kustomization flux-system
