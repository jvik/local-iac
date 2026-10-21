# local-iac

Infrastructure as Code for a homelab built on a single Proxmox VE host, managed with Ansible.

## Goals

- Rebuild the Proxmox host and its guests (VMs and LXC containers) from code.
- Keep configuration idempotent: running a playbook twice changes nothing the second time.
- Keep secrets out of plain text (Ansible Vault).

## Requirements

- [mise](https://mise.jdx.dev) (installs Python, [uv](https://docs.astral.sh/uv/) and
  [just](https://just.systems))
- SSH access to the Proxmox host as `root`, or as a user with sudo
- A Proxmox API token for managing guests (`community.proxmox` collection)

## Setup

```sh
mise trust
mise install      # Python, uv, just; creates .venv
just setup        # vault password, uv sync, Ansible collections into ./collections
```

mise activates `.venv` and sets `ANSIBLE_VAULT_PASSWORD_FILE` when you enter the directory.
Python dependencies are defined in `pyproject.toml` and locked in `uv.lock`; Ansible collections
are in `requirements.yml`. Run `just` to list all recipes.

Add a Python dependency with `uv add <pkg>` (or `uv add --dev <pkg>` for tooling).

## Bootstrap

Ansible talks to the host in two ways:

- **SSH as `root`** (key only) for host configuration.
- **API token `ansible@pve!ansible`** for managing guests through `community.proxmox`. The token
  inherits the custom `Ansible` role, granted on `/`.

`playbooks/bootstrap.yml` sets up both over SSH. See [bootstrap.md](bootstrap.md) for the full
step-by-step procedure, verification and recovery.

## Layout

```
.
├── ansible.cfg              # Project-wide Ansible settings
├── justfile                 # Common commands
├── mise.toml                # Tool versions and env
├── pyproject.toml           # Python deps (managed by uv)
├── requirements.yml         # Galaxy collections and roles
├── inventory/
│   ├── hosts.yml            # Proxmox host(s) and guests
│   ├── group_vars/
│   │   └── all/
│   │       ├── vars.yml     # Non-secret variables
│   │       └── vault.yml    # Encrypted secrets (ansible-vault)
│   └── host_vars/
├── playbooks/
│   ├── site.yml             # Runs everything
│   ├── inventory.yml        # Read-only hardware/storage/network/guest report
│   ├── proxmox.yml          # Host configuration (hardware-specific)
│   └── guests.yml           # VM / LXC provisioning
├── reports/                 # Generated host reports (git-ignored)
└── roles/
    └── <role>/              # One role per concern
```

## Usage

```sh
just ping                              # Check connectivity
just inventory                         # Read-only host report -> reports/<host>.md
just check                             # Dry run site.yml with a diff
just apply                             # Apply site.yml
just check bootstrap --tags api        # Any playbook, extra args pass through
just apply site --limit pve01 --tags ssh
```

## Storage

> **Hardware-specific / one-off.** The storage setup is written for the pve01 hardware (HP Z1 G8)
> and its exact disks. It wipes disks. Review `inventory/host_vars/pve01/vars.yml` against the
> real hardware before running it elsewhere or after a disk change.

The `proxmox_zfs` role (in `playbooks/proxmox.yml`) creates ZFS pools and registers them as
Proxmox storage. Pools and their disks are defined per host in
`inventory/host_vars/<host>/vars.yml`, always by `/dev/disk/by-id` path.

On `pve01`, `tank` is a mirror of the Samsung NVMe and the Kingston A400 for guest disks. The
boot SSD keeps `local` and `local-lvm`.

`proxmox_zfs_retired_lvm` lists empty LVM storages whose disks are handed over to ZFS. The role
refuses to touch disks that are mounted, in another VG, or on a storage that still holds volumes.

```sh
just check proxmox --tags zfs
just apply proxmox --tags zfs
zpool status tank          # on the host
```

## Secrets

Secrets are stored in `inventory/group_vars/all/vault.yml`, encrypted with Ansible Vault.
Reference them from `vars.yml` through `vault_`-prefixed variables:

```yaml
# vars.yml
proxmox_api_token_secret: "{{ vault_proxmox_api_token_secret }}"
```

```sh
just vault-edit
```

| Credential | Where it lives |
| --- | --- |
| SSH access | Your existing SSH key, in `/root/.ssh/authorized_keys` on the host |
| API token secret | `vault_proxmox_api_token_secret` in `vault.yml` (encrypted, committed) |
| Vault password | `~/.config/local-iac/vault-pass` (0600, outside the repo, never committed) |

`just setup` generates the vault password if it is missing. **Back it up in a password manager**:
without it the vault cannot be decrypted. The `ansible@pve` user has no password; it is only
used through its API token.

## Linting

```sh
just lint
```
