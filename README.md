# kube-image

Packer templates and Ansible roles that pre-bake RKE2 node images — OS prep,
SELinux/kernel-module prerequisites, and RKE2 binaries baked in — so
`kube-compute`'s node modules launch from a ready image instead of
bootstrapping from scratch on every apply. Per-cluster identity, secrets, and
join logic stay a launch-time concern (`kube-compute`'s `node-bootstrap`
module), not baked here.

## The bootstrap program is baked, and pinned

`rke2_bake_common` installs `kube-compute`'s node bootstrap program at
`/opt/kube-compute/bootstrap.sh`, from the commit pinned in that role's
`defaults/main.yml`. It is a plain program: `kube-compute`'s `node-bootstrap`
module writes only values, in `/opt/kube-compute/node.env`.

It is baked for the same reason the Cilium and Argo CD renders are. The program
is ~9.6 KB and almost entirely static, and it used to be rendered per node and
delivered in cloud-init -- a genesis node carried three copies, its own plus one
inside each worker group's cloud-init in a CAPI bundle. EC2 allows 16384 decoded
bytes of user data for everything a node boots with, and a real two-group
cluster reached 24627. Proxmox's snippet cap is 1 MiB, which is the same problem
with more room.

The two sides agree on a contract number, in the program and in the module. A
mismatch fails the node's first boot with a message naming both, so **bump the
pin when that program changes**. The bake prints the ref and the contract it
installed, so a boot failure traces back to a build.

`trusted_ca_path` optionally bakes a corporate CA into the trust store, at the
one path `kube-compute` pins containerd's TLS to. The PEM is never committed
here -- it is a path on the build host. It saves the same kind of duplication:
a CA otherwise travels in every node's user data and again inside every worker
group's cloud-init. Set `trusted_ca_in_image = true` in `kube-compute` to match.

A provider-agnostic `rke2_bake_common` Ansible role handles OS prep, RKE2
install, and template cleanup. Each provider adds a thin
`rke2_bake_<provider>` role for whatever's genuinely provider-specific (e.g.
`rke2_bake_aws`'s `amazon-ssm-agent` install) and its own Packer template +
playbook.

## Providers

- **Proxmox** — supported. See `packer/proxmox/README.md`.
- **AWS** — supported. See `packer/aws/README.md`.
- **Azure** — not supported (kube-compute has no viable Ansible transport for it yet).

## Proxmox credentials

The devcontainer sources `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` from
`~/.kube-compute/` automatically. The API token is short-lived (8h) —
refresh it with `kube-proxmox-login` (also a "Proxmox Login" VS Code task)
before running `tofu apply` in `packer/proxmox/seed/` or a Packer build if
it's expired.

## Man in the middle network proxy

Behind a MITM proxy? Drop your org's root CA at
`.devcontainer/org-root-ca.pem` before building the container —
`post-create.sh` installs it into the container's trust store. Not needed
otherwise, and never committed (`.gitignore`).

## Building

```bash
cd packer/proxmox && cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit the copy, then:
packer init . && ./build.sh .
```

```bash
cd packer/aws && cp aws.auto.pkrvars.hcl.example aws.auto.pkrvars.hcl
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
cd packer/proxmox && packer fmt -check . && packer validate .
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
