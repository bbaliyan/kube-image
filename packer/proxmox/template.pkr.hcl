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
  # Proxmox tags allow only [A-Za-z0-9_-] — stricter than VM/template names
  # (which allow dots, confirmed working in image_name above). k8s_version_safe
  # still has dots (e.g. "v1.36.1-rke2r1"), so tags need their own value.
  k8s_version_tag = replace(local.k8s_version_safe, ".", "-")
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
  # Semicolon-separated (packer-plugin-proxmox's Tags is a single string, unlike
  # bpg/proxmox's list-typed tags on the seed) — mirrors the seed's "kube-image"
  # tag so both are findable together in the Proxmox UI, plus "template" (the
  # seed's own tag is "seed-template" — distinct so the two are never confused)
  # and the sanitized k8s_version for quick filtering without opening the VM.
  tags = "kube-image;template;${local.k8s_version_tag}"

  cores  = 2
  memory = 2048
  os     = "l26"

  # Proxmox's own CPU-type default ("kvm64") emulates a baseline pre-SSE4.2 CPU;
  # AlmaLinux 10/RHEL10 userspace assumes more than that's actually there, and
  # booting under kvm64 produced a very early kernel panic ("Attempted to kill
  # init!", a SIGSEGV inside systemd's own startup, present on the seed's own
  # first boot too — not something the scsi_controller/disk settings below caused
  # or fixed) on a real bake. kube-compute's proxmox-control-plane defaults to the
  # named QEMU model "x86-64-v2-AES" instead (for live-migration portability across
  # a running cluster's hosts) — tried that here first, but it produced the
  # identical panic on real hardware (a Dell PowerEdge T630/older Xeon): the named
  # model can claim CPUID features KVM can't actually back on that silicon,
  # producing the same illegal-instruction-flavored crash kvm64 did. var.cpu_type
  # defaults to "host" instead — always exactly what the physical CPU supports,
  # no claimed-but-unbacked features possible. Live-migration portability doesn't
  # apply here: this is a bake-only VM, never migrated. Override if your build
  # host's exact CPU model matters to you for some other reason.
  cpu_type = var.cpu_type

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
    playbook_file = "../../ansible/playbook-proxmox.yml"
    user          = var.ssh_username
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
    ]
  }
}
