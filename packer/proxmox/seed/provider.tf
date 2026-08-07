provider "proxmox" {
  insecure = var.proxmox_insecure
  # endpoint and API token are read from the PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN
  # environment variables (already loaded by kube-image's devcontainer) — never pass
  # the token as a variable.

  # bpg/proxmox always uses SSH (never the API) to upload snippet files, which the
  # vendor_data snippet in main.tf requires. Password auth if proxmox_ssh_password is
  # set (no key setup needed); otherwise private_key from proxmox_ssh_key_file. The
  # file() call is only evaluated when actually selected — Terraform/OpenTofu's
  # conditional expressions short-circuit function calls in the untaken branch, so
  # this doesn't error when proxmox_ssh_key_file doesn't exist and password auth is
  # used instead.
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
