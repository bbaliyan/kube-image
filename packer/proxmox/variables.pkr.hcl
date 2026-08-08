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

variable "cpu_type" {
  type        = string
  default     = "host"
  description = "QEMU CPU model for the build/clone VM. Defaults to 'host' (exactly what the physical Proxmox node supports, no claimed-but-unbacked CPUID features) — a named model like kube-compute's 'x86-64-v2-AES' can claim features KVM can't actually back on some real hardware (confirmed on a Dell PowerEdge T630/older Xeon: produced the same very-early kernel panic Proxmox's own 'kvm64' default does). Live-migration portability across hosts doesn't apply here — this is a bake-only VM, never migrated — so 'host' has no real downside for this use case; override only if your build host's exact CPU model matters to you for some other reason."
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
  description = "RKE2 release string to bake, e.g. v1.36.1+rke2r1. Same neutral naming convention as kube-compute's k8s_version variable — no distro-specific variable name. Resolved automatically by build.sh from kube-platform's platform/platform-versions/values.yaml (k8sVersion) — do not set this in proxmox.auto.pkrvars.hcl (an auto.pkrvars.hcl entry outranks build.sh's PKR_VAR_k8s_version export, silently defeating the live resolution); override at the shell instead if you need a specific pin."
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version. Genesis-installs this pinned chart directly (see helm-values/cilium-values.yaml) — not RKE2's own rke2-cilium HelmChart CRD — into /opt/kube-compute/manifests/cilium.yaml on the template, for node-bootstrap to apply at first boot. Resolved automatically by build.sh from kube-platform's platform/platform-versions/values.yaml (ciliumVersion); same do-not-set-in-proxmox.auto.pkrvars.hcl caveat as k8s_version applies."
}

variable "argocd_version" {
  type        = string
  description = "Argo CD Helm chart version. Genesis-installs this pinned chart (see helm-values/argocd-values.yaml) into /opt/kube-compute/manifests/00-argocd.yaml on the template; only needs to produce *a* working Argo CD — kube-platform's own bootstrap/templates/argocd-app.yaml carries the consumer's chosen ongoing version afterward. Resolved automatically by build.sh from kube-platform's platform/platform-versions/values.yaml (argocdVersion); same do-not-set-in-proxmox.auto.pkrvars.hcl caveat as k8s_version applies."
}

variable "rendered_manifests_dir" {
  type        = string
  description = "Local directory (on the Packer build host) containing the pre-rendered cilium.yaml/00-argocd.yaml to copy onto the template. Always set by build.sh (a fresh mktemp -d per build, rendered via helm template immediately before invoking packer build) — not meant to be set by hand; there is no default so a bare 'packer build' (bypassing build.sh) fails loudly instead of silently baking a stale or missing manifest."
}
