# kube-devbox on Proxmox

This template clones the stock AlmaLinux 10 seed template and runs the shared
`devbox_common` role. The `kube-node` image clones the same seed. See
`kube-node/packer/proxmox/README.md` for how the seed is made.

## Build

1. Verify that the seed template exists. The build clones it.
2. Copy `proxmox.auto.pkrvars.hcl.example` to `proxmox.auto.pkrvars.hcl`.
3. Set the Proxmox URL, the API token and the site values in that file.
4. Run `packer init .`.
5. Run `packer build .`.

The build VM must reach the template VM's address. The bridge name is an input.

## Notes

- This is a skeleton. The role only verifies the base image for now.
- Nothing site-specific goes into the image. The tailnet tag, the allowed addresses and the SSH keys are launch-time inputs.
