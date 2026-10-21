# kube-devbox

The dev box image: a disposable VM for development and validation. It is not a
jump host and not a build server.

- `ansible/` holds `devbox_common`, one role shared by every provider.
- `packer/proxmox/` builds the Proxmox template. An AWS template follows later.
- `tests/` holds fixture variables, so `make test-commit` validates the templates with no cloud access.

The spec is in the cloud-hub repo, in the dev box spec. The box is built from
code, rebuilt instead of repaired, and holds no credentials.
