# =============================================================
# Justfile — homeops infrastructure
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

mod k3s 'infrastructure/k3s/mod.just'

# List all recipes
default:
    @just --list --unsorted --list-submodules

# Install all required tools via mise
tools:
    mise install
