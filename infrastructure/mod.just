set shell := ["bash", "-euo", "pipefail", "-c"]

# Full cluster teardown: uninstall all workloads + Cilium + k3s on all nodes
# WARNING: completely destroys the cluster and all data
teardown:
    #!/usr/bin/env bash
    set -euo pipefail
    gum confirm "Completely destroy cluster and all data? This is irreversible." || exit 0
    just system::uninstall-stack
    just cilium::uninstall
    just metal::teardown
    gum style --foreground 46 --bold "Cluster fully destroyed."

# Provision cluster + install full system stack
install:
    #!/usr/bin/env bash
    set -euo pipefail
    just metal::install
    just metal::copy-kubeconfig
    just system::install-stack
