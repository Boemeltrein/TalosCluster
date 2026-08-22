# AGENTS.md

## Overview

This repository manages a Talos Linux Kubernetes cluster using Flux GitOps.

Make infrastructure and application changes through this repository. Avoid direct changes to the live cluster unless explicitly requested.

## Working in this repository

- Inspect the relevant manifests and existing patterns before making changes.
- Keep changes small, focused, and limited to the requested scope.
- Preserve unrelated changes.
- Prefer reusable Kustomize components where configuration is shared.
- Validate the affected Kustomize or HelmRelease scope before declaring work complete.

## Git and pull requests

- Do not modify `main` directly.
- Create branches, commits, pull requests, or push changes only when explicitly requested.
- Use Conventional Commit titles, for example `feat(scope): description`.
- State what was changed and how it was validated.

## Sensitive data and cluster safety

- Never expose, print, commit, or copy credentials, tokens, passwords, keys, kubeconfigs, or decrypted SOPS data.
- Treat values injected through Flux substitution as sensitive.
- Do not decrypt or edit encrypted secrets unless explicitly requested.
- Do not apply, delete, reconcile, or otherwise mutate live cluster resources unless explicitly requested.

## Validation

- Use read-only inspection for diagnosis.
- Run the narrowest relevant validation available.
- Report validation results and any remaining uncertainty.
