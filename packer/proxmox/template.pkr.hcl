# SPDX-License-Identifier: Apache-2.0
packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  build_date       = formatdate("YYYY-MM-DD", timestamp())
  k8s_version_safe = replace(var.k8s_version, "+", "-")
  image_name       = "kube-image-${local.k8s_version_safe}-${var.cilium_version}-${var.argocd_version}-${local.build_date}"
}

source "proxmox-clone" "rke2" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify

  node                 = var.proxmox_node
  clone_vm_id          = var.seed_template_vm_id
  full_clone           = true
  vm_name              = local.image_name
  template_name        = local.image_name
  template_description = "RKE2 ${var.k8s_version} / Cilium ${var.cilium_version} / Argo CD ${var.argocd_version}, baked ${local.build_date}"

  cores  = 2
  memory = 2048
  os     = "l26"

  # Must match the seed template's own scsi_hardware (packer/proxmox/seed/main.tf,
  # "virtio-scsi-single") — full_clone copies the disk image but Packer's own VM
  # config otherwise defaults the controller to "lsi" (packer-plugin-proxmox's
  # builder/proxmox/common/config.go), a mismatch that produced a kernel panic
  # ("Attempted to kill init!") during boot on a real bake: the plugin's own
  # validation rejects io_thread=true under any controller but virtio-scsi-single,
  # so the seed's inherited iothread setting got silently dropped by Proxmox at
  # clone time under the wrong controller, corrupting I/O.
  scsi_controller = "virtio-scsi-single"

  # Matches kube-compute's proven proxmox_virtual_environment_vm disk block
  # (proxmox-control-plane/main.tf) now that scsi_controller makes io_thread valid.
  disks {
    disk_size    = "20G"
    storage_pool = var.disk_datastore_id
    type         = "scsi"
    io_thread    = true
    discard      = true
    ssd          = true
  }

  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "10m"
}

build {
  name    = "rke2-proxmox"
  sources = ["source.proxmox-clone.rke2"]

  provisioner "ansible" {
    playbook_file = "../../ansible/playbook.yml"
    user          = var.ssh_username
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
    ]
  }
}
