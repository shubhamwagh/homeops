# =============================================================
# Justfile — homeops infrastructure
#
# Install order: cilium → longhorn → cert-manager → vault →
#                eso → postgres → keycloak → adguard → gateway → homepage
#
# Full stack: just install-stack
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

# Infrastructure orchestration (metal + system combined)
mod infra        'infrastructure/mod.just'

# Cluster provisioning (k3s via k3sup + Ansible)
mod metal        'infrastructure/metal/mod.just'

# System components — each has install / uninstall + component-specific recipes
mod cilium       'infrastructure/system/cilium/mod.just'
mod longhorn     'infrastructure/system/longhorn/mod.just'
mod cert-manager 'infrastructure/system/cert-manager/mod.just'
mod vault        'infrastructure/system/vault/mod.just'
mod eso          'infrastructure/system/external-secrets/mod.just'
mod postgres     'infrastructure/system/postgresql/mod.just'
mod keycloak     'infrastructure/system/keycloak/mod.just'
mod adguard      'infrastructure/system/adguard/mod.just'
mod gateway      'infrastructure/system/gateway/mod.just'
mod homepage     'infrastructure/system/homepage/mod.just'
mod skypilot     'infrastructure/system/skypilot/mod.just'

# Install sequence orchestrator
mod system       'infrastructure/system/mod.just'

# Application workloads
mod tandoor      'applications/tandoor/mod.just'

# List all recipes
default:
    @just --list --unsorted --list-submodules

# Install all required tools (brew + mise)
tools:
    brew bundle
    mise install
