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
just setup        # check vault password, uv sync, Ansible collections into ./collections
```

mise activates `.venv` and sets `ANSIBLE_VAULT_PASSWORD_FILE` when you enter the directory. It
points at `scripts/vault-pass`, which reads the vault password from Bitwarden, so unlock first with
`export BW_SESSION="$(bw unlock --raw)"`.
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
│   ├── update.yml           # Automatic updates and an on-demand apt dist-upgrade
│   └── guests.yml           # Cloud images, VMs, k3s kubeconfig, tunnel, secrets, Argo CD,
│                            # Proxmox metrics and logs to k3s
├── kubernetes/
│   └── apps/<app>/          # Cluster infrastructure, applied by guests.yml or just kube-apply
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

## Network

The `proxmox_network` role (in `playbooks/proxmox.yml`) manages all of `/etc/network/interfaces`
from `proxmox_network_bridges` in `inventory/host_vars/<host>/vars.yml`.

On `pve01`, `nic0` is on a switch trunk: VLAN 10 (management, 10.0.10.0/24) untagged and VLAN 50
(servers, 10.0.50.0/24) tagged. `vmbr0` is VLAN-aware and allows VID 50. The host has no IP on
VLAN 50; guests on the server network attach to the `servers` VNet (see below) and get an address
by DHCP.

Before reloading, the role arms a `systemd-run` timer that restores the previous file and reloads
the network. The timer is cancelled only if SSH is still reachable on the management address
afterwards. It refuses to write a config that does not contain `ansible_host`.

```sh
just check proxmox --tags network
just apply proxmox --tags network
```

### SDN

The `proxmox_sdn` role creates SDN zones and VNets from `proxmox_sdn_zones` and
`proxmox_sdn_vnets`, then applies the SDN config. It only adds and updates; zones and VNets not
listed are left alone. On `pve01`, VLAN zone `lan` sits on `vmbr0` and VNet `servers` carries tag
50. Guests use `bridge=servers` with no tag. The VNet tags are the only place VLAN IDs are set:
`vmbr0`'s `vids` is derived from them.

```sh
just check proxmox --tags sdn
just apply proxmox --tags sdn
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

## Updates

`playbooks/update.yml` (not part of `site.yml`) uses the `proxmox_updates` role to:

- **`auto` tag**: install and configure `unattended-upgrades` (Debian, Debian-Security and Proxmox
  origins) so the host updates itself daily. It never reboots on its own unless
  `proxmox_updates_unattended_reboot` is true.
- **`upgrade` tag**: run an `apt dist-upgrade` now and report whether a newer kernel is waiting
  for a reboot. It reboots only with `-e proxmox_updates_reboot=true`.

A reboot stops every guest. The host needs a working apt repository (`pve-no-subscription` or an
enterprise subscription); the playbook does not manage repositories.

```sh
just check update
just apply update --tags auto                          # configure automatic updates only
just apply update --tags upgrade                       # upgrade now, no reboot
just apply update --tags upgrade -e proxmox_updates_reboot=true
```

## Guests

`playbooks/guests.yml` creates VMs from cloud images, configured with cloud-init:

- `proxmox_cloud_images` (SSH, on the Proxmox host) enables `import` and `snippets` content on
  `local` and downloads the pinned images in `proxmox_cloud_images` (`group_vars/all`) into its
  import directory.
- `proxmox_vm` (API token, from the control node) creates one VM per host in the `proxmox_vms`
  inventory group: imports the image as the boot disk, grows it, adds a cloud-init drive and
  starts the VM. Proxmox generates the user data (user, SSH keys, DHCP); `proxmox_vm_vendor_data`
  is written to a snippet and merged in as vendor data. It is create-only: changing hardware or
  cloud-init settings later does not touch an existing VM.
- `proxmox_vm_address` (API token, from the control node) sets `ansible_host` from the QEMU
  guest agent: the IPv4 address on the interface with `net0`'s MAC. It waits for the agent on a new
  VM, skips VMs that do not exist or are stopped, and is not used when `inventory/hosts.yml` has an
  `ansible_host` for the VM. It runs with every tag.
- `qemu_guest_agent` (SSH as `ubuntu` with sudo) waits for cloud-init and keeps
  `qemu-guest-agent` installed and running.

`k3s01` (group `k3s`, VMID 110) is Ubuntu 26.04 LTS with 4 cores, 8 GiB RAM and a 100 GB boot
disk on `tank`, on the `servers` VNet with a pinned MAC for a DHCP reservation. Cloud-init installs
the QEMU guest agent and a single-node k3s server pinned to `k3s_version` (`group_vars/k3s`).

A second 300 GB disk (`scsi1`, `proxmox_vm_data_disk_size`) holds the local-path volumes: cloud-init
formats it as ext4 and mounts it at `/var/lib/rancher/k3s/storage`, and k3s does not start without
it. A full volume then cannot fill the root filesystem, and `tank/vm-110-disk-1` can be snapshotted
or sent with `zfs send` on its own. After raising the size and running `just apply guests`, grow the
filesystem with `sudo resize2fs /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1` in the VM.

Before the first run, add your public key to `proxmox_vm_ssh_public_keys` in
`inventory/group_vars/proxmox_vms/vars.yml`. The API token needs the guest agent privilege; on a
host bootstrapped before it was added, run `just apply bootstrap --tags api` once.

A DHCP reservation is still worth having: the kubeconfig points at the address it had when it was
fetched.

```sh
just check guests
just apply guests
ssh ubuntu@<vm address> sudo k3s kubectl get nodes   # address under the VM's Summary in Proxmox
```

To rebuild a VM, delete it in Proxmox and run `just apply guests` again.

## Kubernetes

The `k3s_kubeconfig` play in `playbooks/guests.yml` (tag `kubeconfig`) copies the k3s admin
kubeconfig to `~/.config/local-iac/kubeconfig` (0600), pointed at the VM's address from
`proxmox_vm_address`. mise installs `kubectl` and sets `KUBECONFIG` to that file inside the repo.
The kubeconfig holds a cluster-admin client key: treat it like the vault password. Run
`just kubeconfig` again after rebuilding the VM or when its address changes.

Workloads live in a separate repository,
[jvik/homelab-workloads](https://github.com/jvik/homelab-workloads), deployed by Argo CD (below).
This repository keeps the cluster infrastructure that Argo CD itself depends on:
`kubernetes/apps/cloudflared`, a Kustomize directory applied by `just apply guests` (below).
`just kube-apply cloudflared` applies the same directory by hand.

```sh
just kubeconfig
kubectl get nodes
```

The `Publish k3s` play in `playbooks/guests.yml` runs from the control node: the
`cloudflare_tunnel` role (tag `tunnel`, below) and `cloudflare_access` (tag `access`) talk to the
Cloudflare API, `k3s_secrets` (tag `secrets`) creates the Secrets in `k3s_secrets`
(`group_vars/k3s`) through `KUBECONFIG`, `cloudflared` (tag `cloudflared`) applies
`kubernetes/apps/cloudflared` and waits for the connector to be ready, and `argocd` (tag `argocd`)
installs Argo CD. Apps reference the Secrets by name; they are never committed to a manifest
repository.

### Argo CD

The `argocd` role installs the Argo CD Helm chart pinned to `argocd_chart_version` with Helm
(installed by mise), and creates the ApplicationSet `workloads`. It turns every directory under
`apps/` in `argocd_workloads_repo_url` into an Application of the same name, deployed to a namespace
of the same name, synced automatically with prune and self-heal. Upgrade Argo CD by changing the
chart version here; everything else goes in the workloads repository.

Argo CD reads the private workloads repository with a read-only deploy key, stored in the vault as
`vault_argocd_workloads_ssh_key` and put in the `argocd/workloads-repo` Secret by `k3s_secrets`.

The UI is on `argocd.bitbu.dev`, behind Cloudflare Access (below), then the Argo CD `admin` login.
TLS ends at Cloudflare, so Argo CD serves plain HTTP to Traefik. The `argocd` CLI does not get past
Access; use `kubectl -n argocd port-forward svc/argocd-server 8080:80` and `--plaintext` instead.

One-time setup:

1. Create the deploy key and add the public half to the workloads repository under Settings >
   Deploy keys, without write access:

   ```sh
   ssh-keygen -t ed25519 -N '' -C argocd@k3s01 -f ~/.config/local-iac/argocd-deploy-key
   ```

2. Store the private key in the vault as `vault_argocd_workloads_ssh_key` (a YAML block scalar,
   `just vault-edit`), then delete both key files.
3. Install Argo CD and check that the apps sync:

   ```sh
   just setup                                    # Helm and kubernetes.core >= 6.4.0
   just apply guests --tags tunnel,access,secrets,argocd
   kubectl -n argocd get applications
   just argocd-password
   ```

The ApplicationSet needs the CRDs from the chart, so `just check` fails at that task until Argo CD
is installed. Apps already applied by hand (such as `hello` before the move) are adopted by Argo CD
on the first sync.

### Cloudflare Access

The `cloudflare_access` role puts each hostname in `cloudflare_access_hostnames` behind a
self-hosted Access application, with one reusable policy (`k3s01 admins`) that allows the
addresses in `cloudflare_access_emails`. Applications of hostnames removed from the list are left
in place. It needs Zero Trust enabled on the account (the free plan is enough); the default
One-time PIN login emails a code to an allowed address.

### Public access (Cloudflare Tunnel)

`kubernetes/apps/cloudflared` runs a Cloudflare Tunnel connector. It connects out to Cloudflare,
so no ports are opened on the router, and Cloudflare terminates TLS.

The `cloudflare_tunnel` role manages the tunnel through the Cloudflare API, from
`group_vars/k3s`:

- Creates a remotely managed tunnel named after the host (`k3s01`) in the account that owns
  `cloudflare_tunnel_zone`, or adopts an existing one with that name.
- Sets the tunnel's routes to exactly `cloudflare_tunnel_hostnames`, all to Traefik, which routes
  by host to the Ingresses. Any other hostname gets a 404. Routes added in the dashboard are
  removed.
- Creates a proxied CNAME to the tunnel for each hostname. Records of hostnames removed from the
  list are left in place; delete them in the dashboard.
- Reads the tunnel token for the `cloudflared` Secret, so the token is never stored in the vault.

Hostnames must be one level below the zone (`<app>.bitbu.dev`): the free Universal SSL certificate
does not cover `<app>.<sub>.bitbu.dev`. The role refuses deeper names.

One-time setup:

1. In the Cloudflare dashboard, under My Profile > API Tokens, create a custom token with
   Account > Cloudflare Tunnel: Edit, Account > Access: Apps and Policies: Edit and Zone > DNS:
   Edit, scoped to your account and the `bitbu.dev` zone.
2. Store it in the vault as `vault_cloudflare_api_token` (`just vault-edit`).
3. Create the tunnel, routes, DNS records and Secret, then start the connector:

   ```sh
   just check guests --tags tunnel,secrets
   just apply guests --tags tunnel,secrets,cloudflared
   kubectl -n cloudflared get pods
   ```

To publish another app, give its Ingress an `<app>.bitbu.dev` host, add the hostname to
`cloudflare_tunnel_hostnames` and run `just apply guests --tags tunnel`. Anything on a public
hostname is reachable by anyone; put admin UIs in `cloudflare_access_hostnames` as well.

```sh
curl https://hello.bitbu.dev/
```

### Observability

The stack itself (VictoriaMetrics, VictoriaLogs, Grafana) is `apps/observability` in the workloads
repository; its README lists the ports and protocols it accepts. This repository provides its
Grafana hostname (`grafana_hostname`, public and behind Access), the `observability/grafana-admin`
Secret, and points the Proxmox host at it. The last play in `playbooks/guests.yml` runs on the host:

- `proxmox_metrics` (tag `metrics`) creates the metric server `k3s` (Datacenter > Metric Server):
  InfluxDB line protocol over UDP to port 8089 on the k3s node.
- `proxmox_syslog` (tag `syslog`) installs rsyslog and forwards all of syslog over TCP, as RFC 5424,
  to port 514 on the k3s node, with a disk queue for when k3s is down.

Both use the k3s node's address from `proxmox_vm_address`, so the VM must be running. If the
router filters traffic between VLANs, allow the management VLAN to reach the k3s node on `8089/udp`
and `514/tcp`.

One-time setup:

1. Store the Grafana admin password in the vault as `vault_grafana_admin_password`
   (`just vault-edit`).
2. Publish Grafana and create the Secret, then push the workloads repository:

   ```sh
   just apply guests --tags tunnel,access,secrets
   ```

3. Once `apps/observability` is synced, point the host at it:

   ```sh
   just check guests --tags metrics,syslog
   just apply guests --tags metrics,syslog
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
| Vault password | Bitwarden note `ansible_vault_password_file_local_iac`, field `password`, read by `scripts/vault-pass` |
| k3s admin kubeconfig | `~/.config/local-iac/kubeconfig` (0600, fetched by `just kubeconfig`) |
| Cloudflare API token | `vault_cloudflare_api_token` in `vault.yml` (encrypted, committed) |
| Cloudflare Tunnel token | Read from the Cloudflare API on each run, stored only in Secret `cloudflared/cloudflared` |
| Workloads repo deploy key | `vault_argocd_workloads_ssh_key` in `vault.yml` (encrypted, committed) |
| Argo CD admin password | Generated on install, in Secret `argocd/argocd-initial-admin-secret` (`just argocd-password`) |
| Grafana admin password | `vault_grafana_admin_password` in `vault.yml` (encrypted, committed), in Secret `observability/grafana-admin` |

`just setup` generates the vault password if it is missing. **Back it up in a password manager**:
without it the vault cannot be decrypted. The `ansible@pve` user has no password; it is only
used through its API token.

## Linting

```sh
just lint
```
