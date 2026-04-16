# =============================================================
# system/mod.just — install sequence orchestrator
#
# Each component has its own module with full recipes.
# This file only defines the install/uninstall order.
#
# Full stack install (after just metal::install):
#   just install-stack
#
# Install order (dependency-driven):
#   1. just cilium::install
#   2. just longhorn::install
#   3. just cert-manager::install  &&  just cert-manager::trust-ca
#   4. just adguard::install       (setup wizard + DNS rewrite before gateway)
#   5. just gateway::install
#   6. just vault::install
#   7. just eso::install
#   8. just postgres::install      (requires vault + eso)
#   9. just keycloak::install      (requires postgres + vault + eso)
#  10. just homepage::install
#  11. just skypilot::install
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

# Install the full stack in dependency order
# Safe to re-run — each component install is idempotent
install-stack:
    #!/usr/bin/env bash
    set -euo pipefail
    just cilium::install
    just longhorn::install
    just cert-manager::install
    just cert-manager::trust-ca
    just adguard::install
    just gateway::install
    just vault::install
    just eso::install
    just postgres::install
    just keycloak::install
    just homepage::install
    just skypilot::install
    gum style --foreground 46 --bold "\nFull stack installed."
    gum style --foreground 226 "  · Complete AdGuard setup wizard at http://192.168.0.3:3000 (if not done yet)"
    gum style --foreground 226 "  · Ensure DNS rewrite exists: *.home.didcot → 192.168.0.9"

# Uninstall full stack in reverse order
# WARNING: destroys all data
uninstall-stack:
    #!/usr/bin/env bash
    set -euo pipefail
    gum confirm "Destroy entire stack and all data? This is irreversible." || exit 0
    just skypilot::uninstall
    just homepage::uninstall
    just keycloak::uninstall
    just postgres::uninstall
    just eso::uninstall
    just vault::uninstall
    just gateway::uninstall
    just adguard::uninstall
    just cert-manager::uninstall
    just longhorn::uninstall
    gum style --foreground 46 --bold "Stack removed."
    gum style --foreground 244 "  · Cilium (CNI) left in place — run 'just infra::teardown' to wipe everything"
