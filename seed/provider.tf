provider "proxmox" {
  insecure = var.proxmox_insecure
  # endpoint and API token are read from the PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN
  # environment variables (already loaded by kube-image's devcontainer) — never pass
  # the token as a variable.

  # bpg/proxmox always uses SSH (never the API) to upload snippet files, which the
  # vendor_data snippet in main.tf requires.
  ssh {
    username    = var.proxmox_ssh_user
    private_key = file(var.proxmox_ssh_key_file)
    node {
      name    = var.proxmox_node
      address = var.proxmox_ssh_address
    }
  }
}
