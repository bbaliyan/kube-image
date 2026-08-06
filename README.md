# kube-image

Packer templates and a shared Ansible bake role that pre-build RKE2 node images —
OS prep, SELinux/kernel-module prerequisites, and RKE2 binaries baked in — so
`kube-compute`'s node modules launch from a ready image instead of bootstrapping
from scratch on every apply. Per-cluster identity, secrets, and join logic stay a
launch-time concern (`kube-compute`'s `node-bootstrap` module), not baked here.

## Providers

- **Proxmox** — supported. See `packer/proxmox/README.md`.
- **AWS** — not yet supported.
- **Azure** — not supported (kube-compute has no viable Ansible transport for it yet).

## Consuming a built image

A build produces a Proxmox VM template named
`kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`. Point
`kube-compute`'s `proxmox-control-plane`/`proxmox-node-pool` modules at it via the
`proxmox_template_vm_id` variable (its numeric Proxmox VM ID). The name is
documentation only — kube-compute performs no compatibility check against it.

## Building

Requires a one-time seed AlmaLinux 10 Proxmox template — see
`packer/proxmox/README.md`'s "One-time setup" (a single automated `tofu apply`,
not a manual step).

```bash
cd packer/proxmox
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl: seed_template_vm_id, k8s_version, cilium_version, argocd_version
packer init .
packer build .
```

## Development

Open in the devcontainer (`ghcr.io/bbaliyan/kube-devenv` + Packer). Requires a local
`kube-devenv:local` image build that includes Packer — rebuild it from
`kube-devenv` if your local image predates the Packer addition. Validate without
a live Proxmox connection:

```bash
cd packer/proxmox && packer fmt -check . && packer validate .
cd ../../ansible && ansible-playbook --syntax-check -i localhost, playbook.yml
```
