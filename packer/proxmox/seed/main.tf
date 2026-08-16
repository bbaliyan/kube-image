resource "proxmox_download_file" "os_image" {
  content_type        = "import"
  datastore_id        = var.iso_datastore_id
  node_name           = var.proxmox_node
  url                 = var.os_image_url
  file_name           = coalesce(var.os_image_file_name, basename(var.os_image_url))
  overwrite_unmanaged = false

  lifecycle {
    precondition {
      condition     = var.os_image_file_name != null || !endswith(var.os_image_url, ".img")
      error_message = "os_image_url ends in '.img' which Proxmox rejects as an import extension. Set os_image_file_name to a .qcow2 filename."
    }
  }
}

# AlmaLinux's GenericCloud image doesn't ship qemu-guest-agent. Without it
# actually installed and running in the guest, Packer's proxmox-clone builder
# (which uses the guest agent to discover the cloned VM's IP) hangs until
# ssh_timeout and fails every build.
resource "proxmox_virtual_environment_file" "vendor_data" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data = join("\n", [
      "#cloud-config",
      "packages:",
      "  - qemu-guest-agent",
      "runcmd:",
      "  - systemctl enable --now qemu-guest-agent",
      "",
    ])
    file_name = "kube-image-seed-vendor-data.yaml"
  }
}

# Created directly as a template (template = true); unverified against a
# real Proxmox apply — if that needs template=true as a follow-up update
# instead, it's a one-line fix.
resource "proxmox_virtual_environment_vm" "seed" {
  name      = "kube-image-seed-almalinux-10"
  node_name = var.proxmox_node
  vm_id     = var.vm_id
  tags      = ["kube-image", "seed-template"]

  template        = true
  started         = false
  stop_on_destroy = true
  tablet_device   = false
  scsi_hardware   = "virtio-scsi-single"

  agent {
    enabled = true
  }

  # See variables.tf's cpu_type — kept consistent with the Packer clone's
  # own cpu_type even though this VM never boots (started=false).
  cpu {
    cores = 1
    type  = var.cpu_type
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.disk_datastore_id
    import_from  = proxmox_download_file.os_image.id
    file_id      = null
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  # Native Proxmox cloud-init user_account lets Packer's proxmox-clone
  # source connect to every clone with no manual seed customization step.
  initialization {
    datastore_id        = var.disk_datastore_id
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_data.id

    user_account {
      username = var.ssh_username
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }
}
