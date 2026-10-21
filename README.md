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
bump the pin when that program changes. `trusted_ca_path` optionally bakes a CA
certificate into the trust store; set `trusted_ca_in_image = true` in `kube-compute`
for nodes booting that image.

A provider-agnostic `rke2_bake_common` Ansible role handles OS prep, RKE2
install, and template cleanup. Each provider adds a thin
`rke2_bake_<provider>` role for whatever's genuinely provider-specific (e.g.
`rke2_bake_aws`'s `amazon-ssm-agent` install) and its own Packer template +
playbook.

The names and tags of the images it builds still say `kube-image` (for
example the `kube-image` tag on Proxmox templates and the `kube-image=true`
AMI tag). They are image identifiers, not the repo name. Do not rename them:
the prune scripts and existing images depend on them.

## Providers

- **Proxmox** — supported. See `kube-node/packer/proxmox/README.md`.
- **AWS** — supported. See `kube-node/packer/aws/README.md`.
- **Azure** — not supported (kube-compute has no viable Ansible transport for it yet).

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

```bash
cd kube-node/packer/aws && cp aws.auto.pkrvars.hcl.example aws.auto.pkrvars.hcl
# edit the copy, then:
packer init . && ./build.sh .
```

See each provider's README for prerequisites, what to edit in the copied
`*.pkrvars.hcl`, and what `build.sh` does beyond a plain `packer build`.

## Consuming a built image

Point `kube-compute`'s node modules at the result: Proxmox's
`proxmox-control-plane`/`proxmox-node-pool` via `proxmox_template_vm_id`;
AWS's `aws-control-plane`/`aws-node-pool` via `os_image_ami_id` (or, for a
multi-region build, by resolving the right regional AMI's `build-id` tag).
See each provider's README for its image-naming convention and tag set.

## Development

Open in the devcontainer — uses `ghcr.io/bbaliyan/kube-devenv`, which
already ships Packer. Validate without a live Proxmox/AWS connection:

```bash
cd kube-node/packer/proxmox && packer fmt -check . && packer validate .
cd ../aws && packer fmt -check . && packer validate .
cd ../../ansible
ansible-playbook --syntax-check -i localhost, playbook-proxmox.yml
ansible-playbook --syntax-check -i localhost, playbook-aws.yml
```

## Checks

Run the commit checks inside the `kube-devenv` image:

```bash
make test-commit
```

They need no cloud access or secrets. `make hooks` turns on a pre-commit hook
that runs the fast subset (`make test-fast`).
