# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project

Homelab IaC for a single Proxmox VE host, managed with Ansible. See [README.md](README.md) for
layout and usage.

## Bootstrap documentation

[bootstrap.md](bootstrap.md) is the step-by-step procedure for taking a fresh Proxmox host and
workstation to a state Ansible can manage. Keep it accurate:

- Update it in the same change whenever you alter the bootstrap flow: `playbooks/bootstrap.yml`,
  the roles it uses, `justfile` recipes, `mise.toml`, inventory or connection settings, how
  secrets are created or stored, or prerequisites.
- Keep steps in execution order and include verification and recovery for each new step.
- If a change makes a step obsolete, remove or rewrite it rather than leaving it stale.

## Conventions

- **YAML**: 2-space indent, `.yml` extension, start files with `---`.
- **Modules**: use fully qualified collection names (`ansible.builtin.copy`, not `copy`).
- **Idempotency**: every task must be safe to re-run. Avoid `command`/`shell`; when unavoidable,
  set `changed_when` and `creates`/`removes` or a guard condition.
- **Naming**: every task and play has a `name`. Role variables are prefixed with the role name
  (`proxmox_network_bridges`, not `bridges`).
- **Roles**: one concern per role. Defaults in `defaults/main.yml`, handlers for service restarts.
- **Templates**: Jinja2 templates live in `roles/<role>/templates/` with a `.j2` suffix and start
  with `{{ ansible_managed | comment }}`.
- **Tags**: tag tasks by concern so plays can be run partially.
- **Booleans**: use `true`/`false`, not `yes`/`no`.
- **Single source of truth**: never repeat a value as a literal. Host names and addresses live
  only in `inventory/hosts.yml`; derive them elsewhere from the inventory
  (`groups['proxmox'] | first`, `hostvars[host].ansible_host`, `inventory_hostname`). Other shared
  values are defined once in `group_vars` and referenced.

## Readability

Everything here is maintained by hand. Code that a person can read and change without help is a
higher priority than compact or clever code.

- **Simple over dense**: prefer several plain tasks to one that does a lot. A reader should
  understand a task from its name and arguments without running it.
- **Jinja**: keep expressions short. Avoid long filter chains, inline `if`/`else`, and building
  lists or dicts in Jinja. Split them into named steps (`set_fact` or task `vars`) or write the
  data out in YAML.
- **Modules over raw calls**: use a module when one exists rather than `ansible.builtin.uri`,
  `command` or `shell`.
- **No premature abstraction**: write the straightforward version for the case at hand. Add
  variables, loops or generic roles only when there is a second real use.
- **Comments**: explain why something is done, or a non-obvious constraint, not what the code
  already says.
- **Errors**: fail with a message that tells the reader what is wrong and what to do (`assert`
  with `fail_msg`), not an undefined-variable error.

## Secrets

- Never write secrets in plain text, including in examples, commit messages, or logs.
- Secrets go in `inventory/group_vars/all/vault.yml` (encrypted) as `vault_*` variables and are
  referenced from regular vars files.
- Use `no_log: true` on tasks that handle secrets.
- Do not decrypt, re-encrypt, or modify vault files unless explicitly asked.

## Safety

The target is a live Proxmox host. Mistakes can take down the host's networking or destroy guests.

- Do not run playbooks against real hosts without explicit approval. Prefer `--check --diff`.
- Be especially careful with network config (`/etc/network/interfaces`), storage, firewall rules,
  and anything that deletes VMs, containers, or disks.
- Prefer additive changes; flag destructive ones clearly.

## Validation

Before finishing a change, run `just lint`, which runs:

```sh
yamllint .
ansible-lint
ansible-playbook playbooks/site.yml --syntax-check
```
