provider "proxmox" {
  insecure = var.proxmox_insecure
  # endpoint and API token are read from the PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN
  # environment variables (already loaded by kube-image's devcontainer) — never pass
  # the token as a variable.
}
