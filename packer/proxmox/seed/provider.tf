provider "proxmox" {
  insecure = var.proxmox_insecure
  # Endpoint and API token come from PROXMOX_VE_ENDPOINT/PROXMOX_VE_API_TOKEN
  # (already loaded by the devcontainer) — never passed as a variable.

  # bpg/proxmox always uses SSH, never the API, to upload the vendor_data
  # snippet in main.tf. file() is only evaluated when password auth isn't
  # selected — OpenTofu short-circuits the untaken branch.
  ssh {
    username    = var.proxmox_ssh_user
    password    = var.proxmox_ssh_password
    private_key = var.proxmox_ssh_password != null ? null : file(var.proxmox_ssh_key_file)
    node {
      name    = var.proxmox_node
      address = var.proxmox_ssh_address
    }
  }
}
