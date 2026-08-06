resource "proxmox_download_file" "os_image" {
  content_type       = "import"
  datastore_id       = var.iso_datastore_id
  node_name          = var.proxmox_node
  url                = var.os_image_url
  file_name          = coalesce(var.os_image_file_name, basename(var.os_image_url))
  overwrite_unmanaged = false

  lifecycle {
    precondition {
      condition     = var.os_image_file_name != null || !endswith(var.os_image_url, ".img")
      error_message = "os_image_url ends in '.img' which Proxmox rejects as an import extension. Set os_image_file_name to a .qcow2 filename."
    }
  }
}

# Created directly as a template (template = true) rather than created-then-converted
# — unverified against a real Proxmox apply (this environment has no Proxmox access);
# if a real apply shows the provider needs template=true applied as a follow-up
# update rather than at creation, that's a one-line fix, not a design change.
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

  cpu {
    cores = 1
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

  # Native Proxmox cloud-init user_account, not a Packer-side cloud-init override —
  # this is what lets Packer's proxmox-clone source (and its own SSH communicator)
  # connect to every clone without any manual seed customization step.
  initialization {
    datastore_id = var.disk_datastore_id

    user_account {
      username = var.ssh_username
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }
}
