variable "proxmox_insecure" {
  description = "Skip TLS certificate verification for the Proxmox API — true for a self-signed PVE cert (the common homelab case), false once PVE uses a cert you trust."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node (hypervisor host) to create the seed template on."
  type        = string
}

variable "disk_datastore_id" {
  description = "Proxmox storage ID for the seed template's disk and cloud-init drive. Must support the 'images' content type."
  type        = string
}

variable "iso_datastore_id" {
  description = "Proxmox storage ID for the downloaded OS image. Must support the 'import' content type. Often the same value as disk_datastore_id, but Proxmox distinguishes the two content types, so kept separate."
  type        = string
}

variable "vm_id" {
  description = "VM ID for the seed template. Null lets Proxmox assign the next available ID."
  type        = number
  default     = null
}

variable "os_image_url" {
  description = "URL of the AlmaLinux 10 GenericCloud qcow2 image to download and use as the seed template's disk. Defaults to the upstream AlmaLinux mirror — override only if you need a different mirror or a non-default AlmaLinux 10 build."
  type        = string
  default     = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
}

variable "os_image_file_name" {
  description = "Override for the filename stored on Proxmox. Null = basename of os_image_url."
  type        = string
  default     = null
}

variable "disk_size_gb" {
  description = "Seed template disk size in GB. Must be at least the source image's virtual size (AlmaLinux 10 GenericCloud's default virtual size is well under 10GB)."
  type        = number
  default     = 10
}

variable "network_bridge" {
  description = "Proxmox network bridge for the seed template's NIC."
  type        = string
  default     = "vmbr0"
}

variable "ssh_username" {
  description = "Cloud-init user baked into the seed template via a native Proxmox cloud-init user_account block (not a Packer-side setting) — every kube-image Packer build's proxmox-clone source connects as this user. Must match packer/proxmox/variables.pkr.hcl's ssh_username."
  type        = string
  default     = "almalinux"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorized for ssh_username via the seed template's cloud-init user_account block. Must correspond to the private key packer/proxmox/variables.pkr.hcl's ssh_private_key_file points at."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
