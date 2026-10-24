# kube-images

Packer templates and Ansible roles that pre-bake machine images. Each image
has its own directory.

| Directory | Image |
|---|---|
| `kube-node/` | RKE2 node image for `kube-compute`. Documented below. |
| `kube-devbox/` | Dev box image: a disposable VM for development and validation. See `kube-devbox/README.md`. |

The commit tier, Renovate config and `make test-commit` live at the root and
cover every directory.

## kube-node

Packer templates and Ansible roles that pre-bake RKE2 node images — OS prep,
SELinux/kernel-module prerequisites, and RKE2 binaries baked in — so
`kube-compute`'s node modules launch from a ready image instead of
bootstrapping from scratch on every apply. Per-cluster identity, secrets, and
join logic stay a launch-time concern (`kube-compute`'s `node-bootstrap`
module), not baked here.

## The bootstrap program is baked

`rke2_bake_common` installs `kube-compute`'s node bootstrap program at
`/opt/kube-compute/bootstrap.sh`, from the commit pinned in its `defaults/main.yml`;
bump the pin when that program changes. The bake fails if the program has no
`BOOTSTRAP_CONTRACT=<n>` line, so an image never boots a node it cannot bootstrap.
`trusted_ca_path` optionally bakes a CA certificate into the trust store; set
`trusted_ca_in_image = true` in `kube-compute` for nodes booting that image.

The `rke2_bake_common` Ansible role handles OS prep, RKE2 install, and template
cleanup. The `rke2_bake_proxmox` role adds the Proxmox-only package
(`iscsi-initiator-utils`). The image carries no cloud agent: the seed template
installs `qemu-guest-agent`.

The names and tags of the images it builds still say `kube-image` (for
example the `kube-image` tag on Proxmox templates). They are image
identifiers, not the repo name. Do not rename them: the prune script and
existing images depend on them.

## Providers

The node image is for Proxmox only. See `kube-node/packer/proxmox/README.md`.
There is no AWS or Azure build. The cluster autoscaler and Cluster API are not
part of the image either.

## Proxmox credentials

The devcontainer sources `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` from
`~/.kube-compute/` automatically. The API token is short-lived (8h) —
refresh it with `kube-proxmox-login` (also a "Proxmox Login" VS Code task)
before running `tofu apply` in `kube-node/packer/proxmox/seed/` or a Packer build if
it's expired.

## Man in the middle network proxy

Behind a MITM proxy? Drop your org's root CA at
`.devcontainer/org-root-ca.pem` before building the container —
`post-create.sh` installs it into the container's trust store. Not needed
otherwise, and never committed (`.gitignore`).

## Building

```bash
cd kube-node/packer/proxmox && cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit the copy, then:
packer init . && ./build.sh .
```

See the Proxmox README for prerequisites, what to edit in the copied
`*.pkrvars.hcl`, and what `build.sh` does beyond a plain `packer build`.

## Consuming a built image

Point `kube-compute`'s `proxmox-control-plane`/`proxmox-node-pool` modules at
the result via `proxmox_template_vm_id`. The Proxmox README has the image
naming convention and tag set.

## Development

Open in the devcontainer — uses `ghcr.io/bbaliyan/kube-devenv`, which
already ships Packer. Validate without a live Proxmox connection:

```bash
cd kube-node/packer/proxmox && packer fmt -check . && packer validate .
cd ../../ansible
ansible-playbook --syntax-check -i localhost, playbook-proxmox.yml
```

## Checks

Run the commit checks inside the `kube-devenv` image:

```bash
make test-commit
```

They need no cloud access or secrets. `make hooks` turns on a pre-commit hook
that runs the fast subset (`make test-fast`).
