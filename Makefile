ANSIBLE := $(HOME)/.local/share/mise/installs/pipx-ansible/latest/ansible/bin/ansible-playbook

METAL_DIR  := infrastructure/metal
INVENTORY  := $(METAL_DIR)/inventory.yml
VARS_FILE  := $(METAL_DIR)/group_vars/all.yml
PLAYBOOKS  := $(METAL_DIR)/playbooks

.PHONY: tools configure install add-node teardown nodes copy-kubeconfig \
        flux-setup-age flux-create-sops-secret flux-bootstrap flux-status flux-sync secrets

# ─── tooling ───────────────────────────────────────────────────────────────

tools:
	brew bundle
	command -v flux  >/dev/null || brew install fluxcd/tap/flux
	command -v age   >/dev/null || brew install age
	command -v sops  >/dev/null || brew install sops
	mise install

# ─── cluster provisioning ──────────────────────────────────────────────────

configure:
	#!/usr/bin/env bash
	set -euo pipefail
	mkdir -p $(METAL_DIR)/group_vars

	if [[ ! -f $(INVENTORY) ]]; then
	  read -rp "SSH user [ubuntu]: "         SSH_USER;  SSH_USER=$${SSH_USER:-ubuntu}
	  read -rp "SSH key path [~/.ssh/id_ed25519]: " SSH_KEY; SSH_KEY=$${SSH_KEY:-~/.ssh/id_ed25519}
	  read -rp "Control-plane IPs (space-separated): " CP_NODES
	  read -rp "Worker IPs (space-separated, or blank): " WRK_NODES
	  read -rp "Cluster name [homelab-cluster]: " CLUSTER_NAME; CLUSTER_NAME=$${CLUSTER_NAME:-homelab-cluster}
	  read -rsp "k3s token (blank = auto-generate): " K3S_TOKEN; echo
	  [[ -z "$$K3S_TOKEN" ]] && K3S_TOKEN=$$(openssl rand -hex 16)

	  # write inventory.yml
	  {
	    echo "all:"
	    echo "  children:"
	    echo "    control_plane:"
	    echo "      hosts:"
	    for ip in $$CP_NODES; do
	      echo "        $$ip:"
	      echo "          ansible_user: $$SSH_USER"
	      echo "          ansible_ssh_private_key_file: $$SSH_KEY"
	    done
	    if [[ -n "$$WRK_NODES" ]]; then
	      echo "    workers:"
	      echo "      hosts:"
	      for ip in $$WRK_NODES; do
	        echo "        $$ip:"
	        echo "          ansible_user: $$SSH_USER"
	        echo "          ansible_ssh_private_key_file: $$SSH_KEY"
	      done
	    fi
	  } > $(INVENTORY)
	  chmod 600 $(INVENTORY)
	  echo "wrote $(INVENTORY)"

	  # write group_vars/all.yml
	  {
	    echo "cluster_name: \"$$CLUSTER_NAME\""
	    echo "k3s_token: \"$$K3S_TOKEN\""
	    echo "k3s_version: \"\""
	    echo "control_plane_vip: \"\""
	    echo "extra_server_args: \"--write-kubeconfig-mode=644 --disable=flannel,local-storage,metrics-server,servicelb,traefik --flannel-backend=none --disable-network-policy --disable-cloud-controller --disable-kube-proxy\""
	    echo "extra_agent_args: \"\""
	    echo "kubeconfig_output: \"$$HOME/.kube/config\""
	  } > $(VARS_FILE)
	  chmod 600 $(VARS_FILE)
	  echo "wrote $(VARS_FILE)"
	else
	  echo "$(INVENTORY) already exists — edit it directly or delete and re-run"
	fi

install: $(INVENTORY)
	$(ANSIBLE) -i $(INVENTORY) $(PLAYBOOKS)/install.yml

add-node: $(INVENTORY)
	$(ANSIBLE) -i $(INVENTORY) $(PLAYBOOKS)/add-node.yml

teardown: $(INVENTORY)
	$(ANSIBLE) -i $(INVENTORY) $(PLAYBOOKS)/teardown.yml

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

$(INVENTORY):
	$(error inventory.yml not found — run: make configure)

# ─── flux / gitops ─────────────────────────────────────────────────────────

flux-setup-age:
	@if [ -f age.agekey ]; then echo "age.agekey already exists"; exit 1; fi
	age-keygen -o age.agekey
	@echo ""
	@echo "Next steps:"
	@echo "  1. Copy the public key above into .sops.yaml (replace age1REPLACEME)"
	@echo "  2. Run: make flux-create-sops-secret"
	@echo "  3. Encrypt secrets: sops --encrypt --in-place apps/base/<app>/secret.sops.yaml"
	@echo "  4. Run: GITHUB_TOKEN=<token> GITHUB_USER=<user> make flux-bootstrap"

flux-create-sops-secret:
	kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic sops-age \
	  --namespace=flux-system \
	  --from-file=age.agekey \
	  --dry-run=client -o yaml | kubectl apply -f -

flux-bootstrap:
	@test -n "$(GITHUB_TOKEN)" || (echo "GITHUB_TOKEN not set" && exit 1)
	@test -n "$(GITHUB_USER)"  || (echo "GITHUB_USER not set"  && exit 1)
	flux bootstrap github \
	  --owner=$(GITHUB_USER) \
	  --repository=homeops \
	  --branch=main \
	  --path=clusters/staging \
	  --personal \
	  --token-auth

secrets:
	@GRAFANA_PASS=$$(openssl rand -base64 24); \
	 PG_PASS=$$(openssl rand -base64 24); \
	 KC_ADMIN_PASS=$$(openssl rand -base64 24); \
	 KC_DB_PASS=$$(openssl rand -base64 24); \
	 TANDOOR_KEY=$$(openssl rand -base64 48); \
	 TANDOOR_DB_PASS=$$(openssl rand -base64 24); \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin-secret\n  namespace: monitoring\nstringData:\n  admin-password: "%s"\n' "$$GRAFANA_PASS" \
	   > infrastructure/base/monitoring/kube-prometheus-stack/secret-grafana-admin.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: postgres-superuser\n  namespace: postgres\nstringData:\n  username: postgres\n  password: "%s"\n' "$$PG_PASS" \
	   > apps/base/postgresql/secret.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: keycloak-secret\n  namespace: keycloak\nstringData:\n  admin-password: "%s"\n  db-password: "%s"\n' "$$KC_ADMIN_PASS" "$$KC_DB_PASS" \
	   > apps/base/keycloak/secret.sops.yaml; \
	 printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: tandoor-secret\n  namespace: tandoor\nstringData:\n  SECRET_KEY: "%s"\n  POSTGRES_PASSWORD: "%s"\n' "$$TANDOOR_KEY" "$$TANDOOR_DB_PASS" \
	   > apps/base/tandoor/secret.sops.yaml; \
	 sops --encrypt --in-place infrastructure/base/monitoring/kube-prometheus-stack/secret-grafana-admin.sops.yaml; \
	 sops --encrypt --in-place apps/base/postgresql/secret.sops.yaml; \
	 sops --encrypt --in-place apps/base/keycloak/secret.sops.yaml; \
	 sops --encrypt --in-place apps/base/tandoor/secret.sops.yaml; \
	 printf '# Generated passwords — store in 1Password, then delete this file\ngrafana:    %s\npostgres:   %s\nkeycloak:   %s\nkc-db:      %s\ntandoor-key:%s\ntandoor-db: %s\n' \
	   "$$GRAFANA_PASS" "$$PG_PASS" "$$KC_ADMIN_PASS" "$$KC_DB_PASS" "$$TANDOOR_KEY" "$$TANDOOR_DB_PASS" > .secrets-plaintext; \
	 echo "Done. Passwords saved to .secrets-plaintext — save them in 1Password and delete the file."

flux-status:
	flux get all -A

flux-sync:
	flux reconcile source git flux-system
	flux reconcile kustomization flux-system
