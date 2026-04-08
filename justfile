# =============================================================
# Justfile — homeops infrastructure
# =============================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

mod metal  'infrastructure/metal/mod.just'
mod system 'infrastructure/system/mod.just'

# List all recipes
default:
    @just --list --unsorted --list-submodules

# Install all required tools via mise
tools:
    mise install
