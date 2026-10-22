set shell := ["bash", "-euo", "pipefail", "-c"]

secrets_dir := env("HOME") / ".config/local-iac"
vault_file := "inventory/group_vars/all/vault.yml"

# List recipes
default:
    @just --list

# Install tools, Python deps, Ansible collections and the vault password
setup: vault-init
    mise install
    uv sync
    ansible-galaxy collection install -r requirements.yml

# Lint and syntax-check everything
lint:
    yamllint .
    ansible-lint
    ansible-playbook playbooks/site.yml --syntax-check

# Check SSH connectivity to the Proxmox hosts
ping:
    ansible proxmox -m ansible.builtin.ping

# Bootstrap SSH hardening and the Ansible API token, then store the token in the vault
bootstrap *args: (_playbook "bootstrap" args) store-token

# Read-only report of host hardware, storage, network and guests, written to reports/<host>.md
inventory *args: (_playbook "inventory" args)

# Fetch the k3s admin kubeconfig to ~/.config/local-iac/kubeconfig
kubeconfig *args: (_playbook "guests" "--tags" "kubeconfig" args)

# Apply a Kustomize app from kubernetes/apps to the k3s cluster
kube-apply app:
    kubectl apply -k kubernetes/apps/{{ app }}

# Delete a Kustomize app from kubernetes/apps from the k3s cluster
kube-delete app:
    kubectl delete -k kubernetes/apps/{{ app }}

# Print the Argo CD admin password generated on install
argocd-password:
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Dry run a playbook with diff
check playbook="site" *args: (_playbook playbook "--check" "--diff" args)

# Apply a playbook
apply playbook="site" *args: (_playbook playbook args)

_playbook playbook *args:
    ansible-playbook playbooks/{{ playbook }}.yml {{ args }}

# Generate the vault password file if it does not exist
vault-init:
    #!/usr/bin/env bash
    set -euo pipefail
    f="$ANSIBLE_VAULT_PASSWORD_FILE"
    if [[ -f "$f" ]]; then exit 0; fi
    mkdir -p -m 700 "$(dirname "$f")"
    (umask 077 && head -c 32 /dev/urandom | base64 > "$f")
    echo "Created vault password at $f. Back it up in your password manager."

# Edit the encrypted vault
vault-edit:
    ansible-vault edit {{ vault_file }}

# Move a newly created API token secret into the vault (host defaults to the first in group proxmox)
store-token host="":
    #!/usr/bin/env bash
    set -euo pipefail
    host="{{ host }}"
    if [[ -z "$host" ]]; then
      host="$(ansible proxmox --list-hosts | awk 'NR == 2 { print $1 }')"
    fi
    token_file="{{ secrets_dir }}/$host-api-token"
    vault="{{ vault_file }}"
    if [[ ! -f "$token_file" ]]; then
      echo "No new token secret at $token_file, vault unchanged."
      exit 0
    fi
    tmp="$(mktemp "$vault.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    {
      echo "---"
      if [[ -f "$vault" ]]; then
        ansible-vault view "$vault" | grep -v -e '^---$' -e '^vault_proxmox_api_token_secret:' || true
      fi
      printf 'vault_proxmox_api_token_secret: "%s"\n' "$(< "$token_file")"
    } | ansible-vault encrypt --output "$tmp"
    mv "$tmp" "$vault"
    rm "$token_file"
    echo "Stored token secret in $vault and removed $token_file."
