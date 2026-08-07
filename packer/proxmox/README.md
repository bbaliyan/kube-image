# Proxmox Packer template

Bakes an RKE2 node image as a Proxmox VM template, cloned from a one-time seed
AlmaLinux 10 template.

## One-time setup: create the seed template

kube-image clones from an existing AlmaLinux 10 Proxmox template rather than
installing from ISO. Create it once per Proxmox cluster with the automated
`seed/` OpenTofu config (a sibling of this directory, `packer/proxmox/seed/`)
— no manual Proxmox UI or `qm` commands. This is a one-time step per Proxmox
cluster, not per build — every subsequent `packer build` clones from the
same seed.

Proxmox API credentials come from `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`
(already loaded by the devcontainer). Uploading the vendor-data snippet that
installs `qemu-guest-agent` on the seed needs a separate SSH connection to the
Proxmox host itself — two ways to authenticate:

**With an SSH key** (default: the dedicated `tofu` PAM user +
`~/.ssh/id_ed25519_tofu` — the same PVE-ops account this project's
`kube-examples` consumer repo already provisions; see its
`live/proxmox/README.md`, "One-time: user and token setup"):

```bash
# From this directory (packer/proxmox/):
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.local
```

**No SSH key set up?** Pass a password instead — override `proxmox_ssh_user`
to whatever account you have a password for:

```bash
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.local \
  -var proxmox_ssh_user=root \
  -var proxmox_ssh_password="$(read -srp 'PVE SSH password: ' p && echo "$p")"
```

(the subshell keeps the password out of shell history and `ps`;
`TF_VAR_proxmox_ssh_password` as an env var works too — never put it in a
committed `.tfvars` file.)

A few things to know before running either command:

- `iso_datastore_id` must support both the `import` and `snippets` content
  types. PVE directory-backed storage typically supports both, but
  `snippets` may need enabling separately — check under
  Datacenter → Storage → your datastore → Content.
- `os_image_url` defaults to the current AlmaLinux 10 GenericCloud image —
  override it only if you need a different mirror or build.
- Note the `seed_template_vm_id` output — that's the `seed_template_vm_id`
  value `proxmox.auto.pkrvars.hcl` needs, below.

## Building

Run `packer` from inside this directory (`packer/proxmox/`) — the Ansible
provisioner's playbook path in `template.pkr.hcl` is relative to the current
working directory, not the repo root.

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl: proxmox_node, seed_template_vm_id,
# disk_datastore_id, k8s_version, cilium_version, argocd_version
packer init .
packer build .
```

`proxmox_url`/`proxmox_api_token_id`/`proxmox_api_token_secret` don't need
editing — inside the devcontainer they're already set as
`PKR_VAR_proxmox_url`/`PKR_VAR_proxmox_api_token_id`/
`PKR_VAR_proxmox_api_token_secret`, derived from the same
`PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` the seed step above uses (see
`.devcontainer/write-env.sh`). Building outside the devcontainer? Set those
three explicitly in `proxmox.auto.pkrvars.hcl` instead (commented-out
examples are in `proxmox.auto.pkrvars.hcl.example`).

## Validating without a live Proxmox connection

```bash
packer fmt -check .
packer validate .
```
