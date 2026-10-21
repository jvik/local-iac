# Bootstrap

How to go from a freshly installed Proxmox host and a new workstation to a state where Ansible can
manage the host. Follow the steps in order.

## 1. Prerequisites

- Proxmox VE is installed on the host and reachable at `10.0.10.233` (node `pve01`).
- Your SSH public key is in root's `authorized_keys` on the host:

  ```sh
  ssh-copy-id root@10.0.10.233
  ssh root@10.0.10.233 true   # must succeed without a password prompt
  ```

- [mise](https://mise.jdx.dev) is installed on your workstation.

## 2. Workstation setup

If the vault already exists (any machine except the first), restore the vault password from your
password manager **before** running `just setup`. Otherwise a new password is generated, and it
cannot decrypt the existing vault.

```sh
mkdir -p -m 700 ~/.config/local-iac
# paste the password into ~/.config/local-iac/vault-pass, then:
chmod 600 ~/.config/local-iac/vault-pass
```

Then:

```sh
mise trust
mise install
just setup
```

On the first machine, `just setup` generates `~/.config/local-iac/vault-pass`. Back it up in your
password manager now.

## 3. Verify connectivity

```sh
just lint
just ping
```

## 4. Bootstrap the host

Keep an existing root SSH session to the host open until step 5 is done, in case SSH login breaks.

```sh
just bootstrap --check --diff
just bootstrap
```

This:

1. Disables SSH password and keyboard-interactive login. Root login with a key is still allowed.
2. Creates the Proxmox role `Ansible` with the privileges in `roles/proxmox_api/defaults/main.yml`,
   plus the guest agent privilege this Proxmox version knows (`VM.GuestAgent.Audit` on PVE 9,
   `VM.Monitor` on PVE 8). Re-running it updates the privileges of an existing role.
3. Creates the user `ansible@pve` (it has no password) and grants it the `Ansible` role on `/`.
4. Creates the API token `ansible@pve!ansible` (inherits the user's privileges).
5. Encrypts the token secret into `inventory/group_vars/all/vault.yml` as
   `vault_proxmox_api_token_secret` and deletes the temporary plaintext copy.

## 5. Verify the bootstrap

```sh
# Key login works
ssh root@10.0.10.233 true
# Password login must be refused
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@10.0.10.233 true
# Prints 1 if the token secret is in the vault
ansible-vault view inventory/group_vars/all/vault.yml | grep -c vault_proxmox_api_token_secret
```

In the Proxmox UI, check that **Datacenter → Permissions → API Tokens** lists `ansible@pve!ansible`.

Commit the encrypted vault:

```sh
git add inventory/group_vars/all/vault.yml
git commit -m "Add Proxmox API token to vault"
```

## 6. Inventory the host

```sh
just inventory
```

Read-only: it changes nothing on the host. It writes `reports/pve01.md` (git-ignored) with the
Proxmox version, CPU, memory, IOMMU, disks with SMART health, LVM/ZFS, Proxmox storage, network
and existing guests. Check it before planning storage or guests, and re-run it after hardware
changes.

## Recovery

- **Token secret lost or needs rotating:** delete the token in the Proxmox UI and run
  `just bootstrap --tags api`. The new secret replaces the old one in the vault.
- **Token created but not stored in the vault** (e.g. `store-token` failed): run `just store-token`.
  The secret is waiting in `~/.config/local-iac/pve01-api-token`.
- **Vault password lost:** the vault cannot be decrypted. Delete `vault.yml` and
  `~/.config/local-iac/vault-pass`, delete the token in the Proxmox UI, then run `just setup` and
  `just bootstrap`.
- **Locked out of SSH:** use the console in the Proxmox web UI (as `root@pam` with a password) and
  remove `/etc/ssh/sshd_config.d/10-local-iac.conf`, then `systemctl reload ssh`.
