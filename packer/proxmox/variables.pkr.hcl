# SPDX-License-Identifier: Apache-2.0

variable "proxmox_url" {
  type        = string
  description = "Proxmox VE API URL, e.g. https://pve.example.com:8006/api2/json. Auto-populated from PROXMOX_VE_ENDPOINT by the devcontainer's PKR_VAR_proxmox_url export (.devcontainer/write-env.sh) — set explicitly only outside that devcontainer."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID, e.g. root@pam!packer. Auto-populated from PROXMOX_VE_API_TOKEN by the devcontainer's PKR_VAR_proxmox_api_token_id export (.devcontainer/write-env.sh) — set explicitly only outside that devcontainer."
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Proxmox API token secret. Auto-populated from PROXMOX_VE_API_TOKEN by the devcontainer's PKR_VAR_proxmox_api_token_secret export (.devcontainer/write-env.sh) — set explicitly only outside that devcontainer."
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node (hypervisor host) to build and store the template on."
}

variable "seed_template_vm_id" {
  type        = number
  description = "VM ID of the one-time seed AlmaLinux 10 template this build clones from. See README.md for how to create it."
}

variable "disk_datastore_id" {
  type        = string
  description = "Proxmox storage ID for the cloned VM's disk, e.g. local-zfs."
}

variable "proxmox_insecure_skip_tls_verify" {
  type        = bool
  default     = true
  description = "Skip TLS certificate verification for the Proxmox API — matches seed/variables.tf's proxmox_insecure default (true for a self-signed PVE cert, the common case)."
}

variable "ssh_username" {
  type        = string
  default     = "almalinux"
  description = "SSH user Packer's communicator and the Ansible provisioner both connect as. Must match the seed template's cloud-init default user."
}

variable "ssh_private_key_file" {
  type        = string
  default     = "~/.ssh/id_ed25519_kube_cluster"
  description = "SSH private key path, matching the seed template's authorized cloud-init public key (seed/variables.tf's ssh_public_key_path — this project's dedicated guest-access key, distinct from the PVE-ops key used to reach the Proxmox API host itself)."
}

variable "k8s_version" {
  type        = string
  description = "RKE2 release string to bake, e.g. v1.36.1+rke2r1. Same neutral naming convention as kube-compute's k8s_version variable — no distro-specific variable name."
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version — not installed by this build (Cilium is a cluster-wide, launch-time concern), but baked into the output template's name so a consumer can tell which pin this image was built alongside."
}

variable "argocd_version" {
  type        = string
  description = "Argo CD Helm chart version — same name-only role as cilium_version above."
}
