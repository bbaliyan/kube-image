variable "proxmox_insecure" {
  description = "Skip TLS certificate verification for the Proxmox API — true for a self-signed PVE cert (the common homelab case), false once PVE uses a cert you trust."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node (hypervisor host) to create the seed template on."
  type        = string
}

variable "proxmox_ssh_user" {
  description = "PAM (Linux) user on the Proxmox host that bpg/proxmox connects as via SSH to upload the vendor-data snippet. Defaults to the dedicated 'tofu' PAM user this project's Proxmox consumers already provision for bpg/proxmox SSH access (see kube-examples' live/proxmox/README.md, \"One-time: user and token setup\") — PVE root SSH login is not assumed to be enabled or key-authorized, and this project deliberately keeps the PVE-ops key separate from the per-VM guest-access key (ssh_public_key_path below) to limit blast radius."
  type        = string
  default     = "tofu"
}

variable "proxmox_ssh_key_file" {
  description = "SSH private key for proxmox_ssh_user, used only for the snippet upload. Defaults to the same PVE-ops key (distinct from the guest-access key below) kube-examples' devcontainer already mounts and bpg/proxmox already uses for cloud-init/vendor-data snippet uploads elsewhere in this project."
  type        = string
  default     = "~/.ssh/id_ed25519_tofu"
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
  description = "Proxmox storage ID for the downloaded OS image and the qemu-guest-agent vendor-data snippet. Must support both the 'import' and 'snippets' content types. Often the same value as disk_datastore_id, but Proxmox distinguishes the content types, so kept separate."
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
  description = "Path to the SSH public key authorized for ssh_username via the seed template's cloud-init user_account block. Defaults to this project's dedicated guest-access key (distinct from proxmox_ssh_key_file's PVE-ops key above) — same key kube-compute's own node-bootstrap/Ansible already uses to reach cluster VMs. Must correspond to the private key packer/proxmox/variables.pkr.hcl's ssh_private_key_file points at."
  type        = string
  default     = "~/.ssh/id_ed25519_kube_cluster.pub"
}
