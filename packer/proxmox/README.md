# Proxmox Packer template

Bakes an RKE2 node image as a Proxmox VM template, cloned from a one-time seed
AlmaLinux 10 template.

## One-time setup: create the seed template

kube-image clones from an existing AlmaLinux 10 Proxmox template rather than
installing from ISO. Create it once per Proxmox cluster with the automated
`seed/` OpenTofu config (a sibling of this directory, `packer/proxmox/seed/`)
— no manual Proxmox UI or `qm` commands:

```bash
# From this directory (packer/proxmox/):
cd seed
tofu init
tofu apply \
  -var proxmox_node=<your-node> \
  -var disk_datastore_id=<your-datastore> \
  -var iso_datastore_id=<your-datastore> \
  -var proxmox_ssh_address=<your-proxmox-host-or-ip>
```

Proxmox API credentials come from `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`
(already loaded by the devcontainer). `proxmox_ssh_address` is separate — the
host/IP OpenTofu SSHes to (no scheme, no `:8006` port) to upload the
vendor-data snippet that installs `qemu-guest-agent`, usually the same host as
`PROXMOX_VE_ENDPOINT`. SSH connects as the dedicated `tofu` PAM user with the
`~/.ssh/id_ed25519_tofu` key — the same PVE-ops account this project's
`kube-examples` consumer repo already provisions (see its
`live/proxmox/README.md`, "One-time: user and token setup"); override
`proxmox_ssh_user`/`proxmox_ssh_key_file` if yours differs. `iso_datastore_id`
must support both the `import` and
`snippets` content types (PVE directory-backed storage typically supports
both, but `snippets` may need enabling separately — check under
Datacenter → Storage → your datastore → Content). `os_image_url` defaults to
the current AlmaLinux 10 GenericCloud image — override it only if you need a
different mirror or build. Note the `seed_template_vm_id` output; that's the
`seed_template_vm_id` value in `proxmox.auto.pkrvars.hcl` below.

This is a one-time step per Proxmox cluster, not per build — every subsequent
`packer build` clones from the same seed.

## Building

Run `packer` from inside this directory (`packer/proxmox/`) — the Ansible
provisioner's playbook path in `template.pkr.hcl` is relative to the current
working directory, not the repo root.

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl
packer init .
packer build .
```

## Validating without a live Proxmox connection

```bash
packer fmt -check .
packer validate .
```
