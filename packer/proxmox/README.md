# Proxmox Packer template

Bakes an RKE2 node image as a Proxmox VM template, cloned from a one-time seed
AlmaLinux 10 template.

## One-time setup: create the seed template

kube-image clones from an existing AlmaLinux 10 Proxmox template rather than
installing from ISO. Create it once, using the same cloud-image download+import
mechanism `kube-compute`'s `proxmox-control-plane` module uses:

1. Download the AlmaLinux 10 GenericCloud qcow2 image to Proxmox storage (via the
   Proxmox UI's "Download from URL" on your datastore, or `pvesm`).
2. Create a VM from it (`qm create` + `qm importdisk`), attach a cloud-init drive,
   and set the boot disk.
3. Set the cloud-init user and SSH public key on the seed so they match this
   template's `ssh_username`/`ssh_private_key_file` variables:
   `qm set <vmid> --ciuser <user> --sshkeys <path-to-pubkey>`.
4. Install and enable `qemu-guest-agent` inside the seed VM's guest OS, then tell
   Proxmox the agent is present: `qm set <vmid> --agent enabled=1`. The
   `proxmox-clone` builder defaults to `qemu_agent = true` and uses the agent to
   discover the cloned builder VM's IP — without this the build hangs until
   `ssh_timeout` and fails.
5. Convert the VM to a template: `qm template <vmid>`.
6. Note the resulting VM ID — that's `seed_template_vm_id` in
   `proxmox.auto.pkrvars.hcl`.

This is a manual, once-per-Proxmox-cluster step, not automated by this repo (per
the design spec's charting decision — CI/build automation is out of scope for v1).

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
