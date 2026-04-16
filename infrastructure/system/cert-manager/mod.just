set shell := ["bash", "-euo", "pipefail", "-c"]

DIR       := source_directory()
METAL_DIR := source_directory() / ".." / ".." / "metal"

# Install cert-manager + create homelab self-signed CA
install:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    gum style --bold --foreground 212 "Installing cert-manager..."
    helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null
    helm repo update jetstack

    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --version v1.17.2 \
      --values "{{DIR}}/values.yaml" \
      --wait

    gum style --foreground 46 "  ✓ cert-manager installed"

    gum style --bold --foreground 212 "Creating Didcot Homelab CA..."
    kubectl apply -f "{{DIR}}/cluster-issuer.yaml"
    kubectl wait certificate homelab-ca -n cert-manager --for=condition=Ready --timeout=60s

    gum style --foreground 46 "  ✓ Homelab CA ready"
    gum style --foreground 212 --bold "  · Trust the CA on your Mac: just cert-manager::trust-ca"

# Export the homelab CA and trust it on macOS
# Also builds a Python-compatible CA bundle for tools like requests/SkyPilot CLI
trust-ca:
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    kubectl get secret homelab-ca-secret -n cert-manager \
      -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/homelab-ca.crt

    gum style --bold --foreground 212 "Adding Didcot Homelab CA to macOS Keychain..."
    sudo security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain /tmp/homelab-ca.crt

    cat /etc/ssl/cert.pem /tmp/homelab-ca.crt > "$HOME/.homelab-ca-bundle.pem"
    if ! grep -q 'REQUESTS_CA_BUNDLE' "$HOME/.zshrc" 2>/dev/null; then
      echo 'export REQUESTS_CA_BUNDLE=~/.homelab-ca-bundle.pem' >> "$HOME/.zshrc"
    fi
    if ! grep -q 'SSL_CERT_FILE' "$HOME/.zshrc" 2>/dev/null; then
      echo 'export SSL_CERT_FILE=~/.homelab-ca-bundle.pem' >> "$HOME/.zshrc"
    fi

    rm /tmp/homelab-ca.crt
    gum style --foreground 46 "  ✓ CA trusted — all *.home.didcot certs will show padlock in browser"
    gum style --foreground 46 "  ✓ Python CA bundle updated (~/.homelab-ca-bundle.pem)"
    gum style --foreground 244 "  · Run: source ~/.zshrc  (or open a new terminal)"

# Remove the homelab CA from macOS Keychain
untrust-ca:
    #!/usr/bin/env bash
    set -euo pipefail
    gum style --bold --foreground 212 "Removing Didcot Homelab CA from macOS Keychain..."
    sudo security delete-certificate -c "Didcot Homelab CA" \
      /Library/Keychains/System.keychain 2>/dev/null || \
      gum style --foreground 244 "  · CA not found in keychain (already removed?)"
    gum style --foreground 46 "  ✓ CA removed from Mac"

# Uninstall cert-manager and remove CA from keychain
uninstall: untrust-ca
    #!/usr/bin/env bash
    set -euo pipefail

    KUBECONFIG=$(yq ".kubeconfig_output" "{{METAL_DIR}}/group_vars/all.yml" 2>/dev/null || echo "$HOME/.kube/config")
    export KUBECONFIG

    if kubectl get crd clusterissuers.cert-manager.io &>/dev/null; then
      kubectl delete clusterissuer selfsigned-issuer homelab-ca-issuer --ignore-not-found
      kubectl delete certificate homelab-ca -n cert-manager --ignore-not-found
    fi
    helm uninstall cert-manager -n cert-manager --wait 2>/dev/null || true
    kubectl get crd -o name | grep cert-manager | xargs --no-run-if-empty kubectl delete --ignore-not-found 2>/dev/null || true
    kubectl delete namespace cert-manager --ignore-not-found
    gum style --foreground 46 "  ✓ cert-manager removed"
