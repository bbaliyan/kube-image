variable "proxmox_insecure" {
  description = "Skip TLS certificate verification for the Proxmox API — true for a self-signed PVE cert (the common case)."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node (hypervisor host) to create the seed template on."
  type        = string
}

variable "cpu_type" {
  description = "QEMU CPU model for the seed VM. Defaults to 'host' — see packer/proxmox/template.pkr.hcl's cpu_type for why. This VM never boots (started=false below); kept consistent for anyone booting the seed directly to validate."
  type        = string
  default     = "host"
}

variable "proxmox_ssh_user" {
  description = "PAM user on the Proxmox host that bpg/proxmox connects as via SSH to upload the vendor-data snippet. Defaults to the dedicated 'tofu' PAM user this project's Proxmox consumers already provision (kube-examples' live/proxmox/README.md) — kept separate from the per-VM guest-access key below to limit blast radius."
  type        = string
  default     = "tofu"
}

variable "proxmox_ssh_key_file" {
  description = "SSH private key for proxmox_ssh_user, used only for the snippet upload. Ignored when proxmox_ssh_password is set."
  type        = string
  default     = "~/.ssh/id_ed25519_tofu"
}

variable "proxmox_ssh_password" {
  description = "Password for proxmox_ssh_user, as an alternative to proxmox_ssh_key_file. Sensitive — pass via TF_VAR_proxmox_ssh_password or -var, never a committed .tfvars file."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_ssh_address" {
  description = "Hostname or IP Terraform uses to SSH to the Proxmox node for the snippet upload — usually the same host as PROXMOX_VE_ENDPOINT, without the https:// scheme or :8006 port."
  type        = string
}

variable "disk_datastore_id" {
  description = "Proxmox storage ID for the seed template's disk and cloud-init drive. Must support the 'images' content type."
  type        = string
}

variable "iso_datastore_id" {
  description = "Proxmox storage ID for the downloaded OS image and the qemu-guest-agent vendor-data snippet. Must support both the 'import' and 'snippets' content types."
  type        = string
}

variable "vm_id" {
  description = "VM ID for the seed template. Null lets Proxmox assign the next available ID."
  type        = number
  default     = null
}

variable "os_image_url" {
  description = "URL of the AlmaLinux 10 GenericCloud qcow2 image to download and use as the seed template's disk."
  type        = string
  default     = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
}

variable "os_image_file_name" {
  description = "Override for the filename stored on Proxmox. Null = basename of os_image_url."
  type        = string
  default     = null
}

variable "disk_size_gb" {
  description = "Seed template disk size in GB. Must be at least the source image's virtual size."
  type        = number
  default     = 10
}

variable "network_bridge" {
  description = "Proxmox network bridge for the seed template's NIC."
  type        = string
  default     = "vmbr0"
}

variable "ssh_username" {
  description = "Cloud-init user baked into the seed template. Must match packer/proxmox/variables.pkr.hcl's ssh_username."
  type        = string
  default     = "almalinux"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorized for ssh_username. Must correspond to the private key packer/proxmox/variables.pkr.hcl's ssh_private_key_file points at."
  type        = string
  default     = "~/.ssh/id_ed25519_kube_cluster.pub"
}
