# SPDX-License-Identifier: Apache-2.0
# proxmox-autoscaler-worker: a second, lighter Packer build target, sibling to
# template.pkr.hcl's "rke2-proxmox" build in this same directory (Packer loads
# every *.pkr.hcl file in a directory as one merged config, so no change to
# template.pkr.hcl is needed to "wire this in" — the source/build blocks below
# are enough). Reuses the same connection-level variables (proxmox_url,
# proxmox_node, seed_template_vm_id, disk_datastore_id, cpu_type, ssh_*) and
# the same clone/hardware shape as source.proxmox-clone.rke2 — only the image
# naming/tags and the provisioner (a different Ansible playbook) differ.
#
# Unlike the existing build, this template does NOT get RKE2 fully installed.
# It stages CAPI + CAPMOX + CAPRKE2 install manifests
# (/opt/kube-compute/manifests/capi-install.yaml) and RKE2's own air-gap
# release artifacts (/opt/install.sh + /opt/rke2-artifacts/*) for
# cluster-autoscaler-managed CAPI Machines to consume via CAPRKE2's own
# boot-time install.sh re-invocation — see ansible/roles/rke2_bake_autoscaler_worker.

locals {
  autoscaler_build_date       = formatdate("YYYY-MM-DD", timestamp())
  autoscaler_k8s_version_safe = replace(var.k8s_version, "+", "-")
  autoscaler_image_name       = "kube-image-autoscaler-worker-${local.autoscaler_k8s_version_safe}-${var.capi_core_version}-${var.capmox_version}-${var.caprke2_version}-${local.autoscaler_build_date}"
  # Same Proxmox tag-charset constraint as template.pkr.hcl's k8s_version_tag
  # (tags allow only [A-Za-z0-9_-], names allow dots).
  autoscaler_k8s_version_tag = replace(local.autoscaler_k8s_version_safe, ".", "-")
}

source "proxmox-clone" "autoscaler-worker" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify

  node                 = var.proxmox_node
  clone_vm_id          = var.seed_template_vm_id
  full_clone           = true
  vm_name              = local.autoscaler_image_name
  template_name        = local.autoscaler_image_name
  template_description = "CAPI ${var.capi_core_version} / CAPMOX ${var.capmox_version} / CAPRKE2 ${var.caprke2_version}, RKE2 ${var.k8s_version} air-gap artifacts staged, baked ${local.autoscaler_build_date}"
  # "autoscaler-worker" distinguishes this from the rke2-proxmox build's own
  # templates in the Proxmox UI and in prune-images.sh's tag-based selection
  # (both flavors still carry "kube-image;template" and so are found/pruned
  # together — prune-images.sh sorts by name across both, see its own header
  # comment; not changed by this build target, a pre-existing limitation).
  tags = "kube-image;template;autoscaler-worker;${local.autoscaler_k8s_version_tag}"

  cores  = 2
  memory = 2048
  os     = "l26"

  # Same "host" CPU-type rationale as template.pkr.hcl (bake-only VM, never
  # live-migrated; a named model can claim CPUID features KVM can't actually
  # back on real hardware) — see that file's comment for the full story.
  cpu_type = var.cpu_type

  # Must match the seed template's own scsi_hardware, same as template.pkr.hcl.
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
  name    = "proxmox-autoscaler-worker"
  sources = ["source.proxmox-clone.autoscaler-worker"]

  provisioner "ansible" {
    playbook_file = "../../ansible/playbook-proxmox-autoscaler-worker.yml"
    user          = var.ssh_username
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_capi_manifests_dir=${var.rendered_capi_manifests_dir}",
      "--extra-vars", "rendered_rke2_artifacts_dir=${var.rendered_rke2_artifacts_dir}",
    ]
  }
}
