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
  build_date = formatdate("YYYY-MM-DD", timestamp())
  image_name = "almalinux10-kube-devbox-${local.build_date}"
}

source "proxmox-clone" "devbox" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify

  node                 = var.proxmox_node
  clone_vm_id          = var.seed_template_vm_id
  full_clone           = true
  vm_name              = local.image_name
  template_name        = local.image_name
  template_description = "Dev box image, baked ${local.build_date}"
  # Proxmox tags allow only [A-Za-z0-9_-], separated by semicolons here.
  tags = "kube-devbox;template;almalinux10;seed-vm-${var.seed_template_vm_id}"

  cores    = 2
  memory   = 2048
  os       = "l26"
  cpu_type = var.cpu_type

  # Must match the seed template controller. io_thread is valid only under virtio-scsi-single.
  scsi_controller = "virtio-scsi-single"

  disks {
    disk_size    = var.build_disk_size
    storage_pool = var.disk_datastore_id
    type         = "scsi"
    io_thread    = true
    discard      = true
    ssd          = true
  }

  network_adapters {
    bridge = var.network_bridge
    model  = "virtio"
  }

  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "10m"
}

build {
  name    = "devbox-proxmox"
  sources = ["source.proxmox-clone.devbox"]

  provisioner "ansible" {
    playbook_file    = "../../ansible/playbook-proxmox.yml"
    user             = var.ssh_username
    use_proxy        = false
    ansible_env_vars = ["ANSIBLE_PIPELINING=True"]
  }
}
