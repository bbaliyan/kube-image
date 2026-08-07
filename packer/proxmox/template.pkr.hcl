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

  # Matches kube-compute's proxmox-control-plane vm_cpu_type default exactly.
  # Proxmox's own CPU-type default ("kvm64") emulates a baseline pre-SSE4.2 CPU;
  # AlmaLinux 10/RHEL10 userspace assumes an x86-64-v2 baseline, and booting under
  # kvm64 produced a very early kernel panic ("Attempted to kill init!", a SIGSEGV
  # inside systemd's own startup, present on the seed's own first boot too — not
  # something the scsi_controller/disk settings below caused or fixed) on a real
  # bake — confirmed by cross-checking kube-compute's proven, already-working VM
  # config rather than guessing.
  cpu_type = "x86-64-v2-AES"

  # Must match the seed template's own scsi_hardware (packer/proxmox/seed/main.tf,
  # "virtio-scsi-single") — full_clone copies the disk image but Packer's own VM
  # config otherwise defaults the controller to "lsi" (packer-plugin-proxmox's
  # builder/proxmox/common/config.go). The plugin's own validation rejects
  # io_thread=true under any controller but virtio-scsi-single, so without this the
  # seed's inherited iothread disk setting gets silently dropped by Proxmox at
  # clone time — a real, separate correctness issue, kept even though it turned
  # out not to be what caused the panic above.
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
