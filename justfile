# nix-better-gc — task runner. Run inside `nix develop` for shellcheck/just/deps.

# List available recipes
default:
    @just --list

# Lint gc-plan.sh with shellcheck
check:
    shellcheck gc-plan.sh

# Plan a cleanup to free TARGET (e.g. 10G, 500MiB); deletes nothing
plan target:
    ./gc-plan.sh {{target}}
