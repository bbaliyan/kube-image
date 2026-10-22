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

- The seed template must have a cloud-init drive and the QEMU guest agent. The clone keeps them. Each clone then takes its keys and launch inputs from cloud-init.
- The build removes the SSH host keys, the machine ID and the cloud-init state, so every clone makes its own.
- Nothing site-specific goes into the image. The tailnet tag, the allowed addresses and the SSH keys are launch-time inputs. See `kube-devbox/README.md`.
- A real build is run by the operator. The fixture tests only validate the template.
