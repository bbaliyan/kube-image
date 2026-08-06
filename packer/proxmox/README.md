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
   set the boot disk, then `qm template <vmid>` to convert it to a template.
3. Note the resulting VM ID — that's `seed_template_vm_id` in
   `proxmox.auto.pkrvars.hcl`.

This is a manual, once-per-Proxmox-cluster step, not automated by this repo (per
the design spec's charting decision — CI/build automation is out of scope for v1).

## Building

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
