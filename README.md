# kube-image

Packer templates and Ansible bake roles that pre-build RKE2 node images —
OS prep, SELinux/kernel-module prerequisites, and RKE2 binaries baked in — so
`kube-compute`'s node modules launch from a ready image instead of bootstrapping
from scratch on every apply. Per-cluster identity, secrets, and join logic stay a
launch-time concern (`kube-compute`'s `node-bootstrap` module), not baked here.

Ansible is split into a provider-agnostic `rke2_bake_common` role (OS prep,
RKE2 install, template cleanup — the same regardless of provider) plus a thin
`rke2_bake_<provider>` role for whatever's genuinely provider-specific (e.g.
`rke2_bake_proxmox`'s hot-vCPU udev rule). Each provider gets its own Packer
template and its own playbook (`ansible/playbook-<provider>.yml`) that
includes both roles — the provider is known at build-invocation time, so
there's no runtime `node_provider` conditional anywhere.

## Providers

- **Proxmox** — supported. See `packer/proxmox/README.md`.
- **AWS** — not yet supported.
- **Azure** — not supported (kube-compute has no viable Ansible transport for it yet).

## Proxmox credentials

The devcontainer sources `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` from
`~/.kube-compute/` automatically (see `.devcontainer/devcontainer.json`), but the
API token is short-lived (8h). Refresh it with `kube-proxmox-login` — a plain
shell command, also available as the "Proxmox Login" VS Code task — before
running `tofu apply` in `packer/proxmox/seed/` or a Packer build if it's expired.
No cluster-selection step needed here (unlike `kube-compute`'s `kube-cloud-login`)
— kube-image only ever talks to Proxmox.

## Building

Requires a one-time seed AlmaLinux 10 Proxmox template — see
`packer/proxmox/README.md`'s "One-time setup" (a single automated `tofu apply`,
not a manual step).

```bash
cd packer/proxmox
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl: proxmox_node, seed_template_vm_id, disk_datastore_id,
# k8s_version, cilium_version, argocd_version — Proxmox URL/API token don't need
# editing, ./build.sh derives them fresh from PROXMOX_VE_ENDPOINT/PROXMOX_VE_API_TOKEN
# on every run (see packer/proxmox/README.md's "Building" section for why a plain
# 'packer build' isn't used directly)
packer init .
./build.sh .
```

## Consuming a built image

A build produces a Proxmox VM template named
`kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`. Point
`kube-compute`'s `proxmox-control-plane`/`proxmox-node-pool` modules at it via the
`proxmox_template_vm_id` variable (its numeric Proxmox VM ID). The name is
documentation only — kube-compute performs no compatibility check against it.

## Development

Open in the devcontainer (`ghcr.io/bbaliyan/kube-devenv` + Packer). Requires a local
`kube-devenv:local` image build that includes Packer — rebuild it from
`kube-devenv` if your local image predates the Packer addition. Validate without
a live Proxmox connection:

```bash
cd packer/proxmox && packer fmt -check . && packer validate .
cd ../../ansible && ansible-playbook --syntax-check -i localhost, playbook-proxmox.yml
```
