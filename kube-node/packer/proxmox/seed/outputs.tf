output "seed_template_vm_id" {
  description = "VM ID of the newly-created seed template. Set kube-node/packer/proxmox/proxmox.auto.pkrvars.hcl's seed_template_vm_id to this value."
  value       = proxmox_virtual_environment_vm.seed.vm_id
}
