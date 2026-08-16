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
  build_date  = formatdate("YYYY-MM-DD", timestamp())
  distro_slug = "almalinux10" # bump alongside the seed template if this project ever moves off it
  # Proxmox tags allow only [A-Za-z0-9_-] — stricter than VM/template names
  # (which allow dots).
  k8s_version_safe = replace(var.k8s_version, "+", "-")
  k8s_version_tag  = replace(local.k8s_version_safe, ".", "-")
  image_name       = "${local.distro_slug}-kube-image-${local.k8s_version_safe}-${var.cilium_version}-${var.argocd_version}-${local.build_date}"
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
  # Semicolon-separated (packer-plugin-proxmox's Tags is a single string,
  # unlike bpg/proxmox's list-typed tags on the seed). seed-vm-<id> traces
  # this build back to the seed it cloned from — Proxmox has no queryable
  # "resolved source" the way AWS's source-ami-id tag does.
  tags = "kube-image;template;${local.k8s_version_tag};${local.distro_slug};seed-vm-${var.seed_template_vm_id}"

  cores  = 2
  memory = 2048
  os     = "l26"

  # Proxmox's "kvm64" default emulates a pre-SSE4.2 CPU that AlmaLinux
  # 10/RHEL10 userspace assumes more than — booting under it panics very
  # early ("Attempted to kill init!"). The named model "x86-64-v2-AES"
  # (kube-compute's proxmox-control-plane default, for live-migration
  # portability) hit the identical panic on real hardware (Dell PowerEdge
  # T630/older Xeon): it can claim CPUID features KVM can't actually back on
  # that silicon. "host" always matches exactly what the physical CPU
  # supports. Live-migration portability doesn't apply here — bake-only VM,
  # never migrated.
  cpu_type = var.cpu_type

  # Must match the seed template's own scsi_hardware (packer/proxmox/seed/main.tf)
  # — full_clone copies the disk but Packer's own VM config otherwise
  # defaults the controller to "lsi", and io_thread=true is only valid under
  # virtio-scsi-single.
  scsi_controller = "virtio-scsi-single"

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
    # Default (true) tunnels ansible-playbook's SSH through Packer's own
    # proxy adapter. rke2_bake_common's mid-play reboot kills that
    # underlying session, and ansible.builtin.reboot's reconnect logic can't
    # recover a dead proxy, only a real socket — the build hangs
    # indefinitely. use_proxy=false dials the VM's real IP directly instead,
    # so a plain TCP retry succeeds once it's back up. Requires the build
    # host to reach the VM's IP directly (true here — same LAN as Proxmox).
    use_proxy = false
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
      "--extra-vars", "rendered_capi_manifests_dir=${var.rendered_capi_manifests_dir}",
    ]
  }
}
