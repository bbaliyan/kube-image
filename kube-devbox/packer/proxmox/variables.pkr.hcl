# SPDX-License-Identifier: Apache-2.0

variable "proxmox_url" {
  type        = string
  description = "Proxmox VE API URL, for example https://pve.example.com:8006/api2/json."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID, for example root@pam!packer."
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Proxmox API token secret."
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node (hypervisor host) that builds and stores the template."
}

variable "seed_template_vm_id" {
  type        = number
  description = "VM ID of the stock AlmaLinux 10 seed template this build clones from. The kube-node image uses the same seed."
}

variable "disk_datastore_id" {
  type        = string
  description = "Proxmox storage ID for the cloned VM disk."
}

variable "network_bridge" {
  type        = string
  description = "Bridge the build VM attaches to. The build VM must reach the template VM's address."
}

variable "proxmox_insecure_skip_tls_verify" {
  type        = bool
  default     = true
  description = "Skip TLS certificate verification for the Proxmox API. True by default for a self-signed certificate."
}

variable "cpu_type" {
  type        = string
  default     = "host"
  description = "QEMU CPU model for the build VM. See kube-node/packer/proxmox/template.pkr.hcl for why AlmaLinux 10 needs 'host'."
}

variable "build_disk_size" {
  type        = string
  default     = "20G"
  description = "Disk size of the template. The OpenTofu unit that creates the dev box resizes the disk at clone time."
}

variable "ssh_username" {
  type        = string
  default     = "almalinux"
  description = "SSH user for Packer and Ansible. Must match the cloud-init default user of the seed template."
}

variable "ssh_private_key_file" {
  type        = string
  default     = "~/.ssh/id_ed25519_kube_devbox"
  description = "SSH private key path. Its public half must be in the cloud-init keys of the seed template."
}
