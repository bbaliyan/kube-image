# SPDX-License-Identifier: Apache-2.0

variable "proxmox_url" {
  type        = string
  description = "Proxmox VE API URL, e.g. https://pve.example.com:8006/api2/json. Auto-populated from PROXMOX_VE_ENDPOINT inside the devcontainer — set explicitly only outside it."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID, e.g. root@pam!packer. Auto-populated from PROXMOX_VE_API_TOKEN inside the devcontainer."
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Proxmox API token secret. Auto-populated from PROXMOX_VE_API_TOKEN inside the devcontainer."
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node (hypervisor host) to build and store the template on."
}

variable "seed_template_vm_id" {
  type        = number
  description = "VM ID of the one-time seed AlmaLinux 10 template this build clones from. See README.md."
}

variable "disk_datastore_id" {
  type        = string
  description = "Proxmox storage ID for the cloned VM's disk, e.g. local-zfs."
}

variable "proxmox_insecure_skip_tls_verify" {
  type        = bool
  default     = true
  description = "Skip TLS certificate verification for the Proxmox API — true by default for a self-signed PVE cert, the common case."
}

variable "cpu_type" {
  type        = string
  default     = "host"
  description = "QEMU CPU model for the build/clone VM. See template.pkr.hcl for why this defaults to 'host' rather than a named model."
}

variable "ssh_username" {
  type        = string
  default     = "almalinux"
  description = "SSH user Packer and the Ansible provisioner both connect as. Must match the seed template's cloud-init default user."
}

variable "ssh_private_key_file" {
  type        = string
  default     = "~/.ssh/id_ed25519_kube_cluster"
  description = "SSH private key path, matching the seed template's authorized cloud-init public key (distinct from the PVE-ops key used to reach the Proxmox API host itself)."
}

variable "k8s_version" {
  type        = string
  description = "RKE2 release string to bake, e.g. v1.36.1+rke2r1. Resolved automatically by build.sh — do not set in proxmox.auto.pkrvars.hcl, it silently outranks build.sh's fetch."
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version, genesis-installed into /opt/kube-compute/manifests/cilium.yaml. Resolved automatically by build.sh — same do-not-set caveat as k8s_version."
}

variable "argocd_version" {
  type        = string
  description = "Argo CD Helm chart version, genesis-installed into /opt/kube-compute/manifests/00-argocd.yaml. Resolved automatically by build.sh — same do-not-set caveat as k8s_version."
}

variable "rendered_manifests_dir" {
  type        = string
  description = "Directory containing the pre-rendered cilium.yaml/00-argocd.yaml to copy onto the template. Always set by build.sh — no default, so a bare 'packer build' fails loudly instead of baking a stale manifest."
}

variable "rendered_capi_manifests_dir" {
  type        = string
  description = "Directory containing the pre-rendered capi-install.yaml (CAPI core + CAPMOX only) to copy onto the template. Always set by build.sh — same no-default reasoning as rendered_manifests_dir."
}

variable "capi_core_version" {
  type        = string
  description = "Cluster API core version staged via 'clusterctl generate provider --core', e.g. v1.9.5. Resolved automatically by build.sh — same do-not-set caveat as k8s_version."
}

variable "capmox_version" {
  type        = string
  description = "cluster-api-provider-proxmox (CAPMOX) infrastructure provider version, e.g. v0.6.4. Same resolution and caveat as capi_core_version."
}
