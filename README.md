# kube-image

Packer templates and Ansible bake roles that pre-build RKE2 node images —
OS prep, SELinux/kernel-module prerequisites, and RKE2 binaries baked in — so
`kube-compute`'s node modules launch from a ready image instead of bootstrapping
from scratch on every apply. Per-cluster identity, secrets, and join logic stay a
launch-time concern (`kube-compute`'s `node-bootstrap` module), not baked here.

Ansible is split into a provider-agnostic `rke2_bake_common` role (OS prep,
RKE2 install, template cleanup — the same regardless of provider) plus a thin
`rke2_bake_<provider>` role for whatever's genuinely provider-specific (e.g.
`rke2_bake_aws`'s `amazon-ssm-agent` install). Each provider gets its own
Packer template and its own playbook (`ansible/playbook-<provider>.yml`) that
includes `rke2_bake_common` plus its own provider role, if it has one —
Proxmox currently has no provider-specific tasks at all, so
`playbook-proxmox.yml` includes only `rke2_bake_common`. The provider is
known at build-invocation time either way, so there's no runtime
`node_provider` conditional anywhere.

## Providers

- **Proxmox** — supported. See `packer/proxmox/README.md`.
- **AWS** — supported. See `packer/aws/README.md`.
- **Azure** — not supported (kube-compute has no viable Ansible transport for it yet).

## Proxmox credentials

The devcontainer sources `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` from
`~/.kube-compute/` automatically (see `.devcontainer/devcontainer.json`), but the
API token is short-lived (8h). Refresh it with `kube-proxmox-login` — a plain
shell command, also available as the "Proxmox Login" VS Code task — before
running `tofu apply` in `packer/proxmox/seed/` or a Packer build if it's expired.

## Man in the middle network proxy

Behind a MITM network proxy? Drop your org's root CA at
`.devcontainer/org-root-ca.pem` before building the container —
`post-create.sh` installs it into the container's trust store, otherwise TLS
to GitHub/Helm/RKE2/AlmaLinux repos fails inside the container even though
it works on the host. Not needed outside such a network, and never
committed (`.gitignore`).

## AWS credentials

Standard AWS credential chain (env vars, `~/.aws/credentials`, an assumed
role, etc.) — the same way the AWS CLI and Terraform's AWS provider resolve
credentials. Nothing kube-image-specific to set up beyond what
`packer/aws/README.md`'s prerequisites list (notably that the build host
needs a direct network path to the build instance on port 22, and a
`security_group_source_cidrs` value scoping who's allowed to reach it).

## Building

**Proxmox** requires a one-time seed AlmaLinux 10 Proxmox template — see
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

**AWS** needs no seed step — it builds from the AlmaLinux OS Foundation's own
published AlmaLinux 10 AMI directly. See `packer/aws/README.md` for the full
prerequisites (notably `security_group_source_cidrs`, required, and network
reachability to the build instance).

```bash
cd packer/aws
cp aws.auto.pkrvars.hcl.example aws.auto.pkrvars.hcl
# edit aws.auto.pkrvars.hcl: aws_region, security_group_source_cidrs, and
# subnet_id/ami_architecture if needed
packer init .
./build.sh .
```

## Consuming a built image

Both providers produce a self-descriptively named image. Proxmox:
`almalinux10-kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`.
AWS adds an architecture segment, since one AWS build can target either
x86_64 or arm64 (Proxmox only ever builds one architecture, so it doesn't
need one):
`almalinux10-<architecture>-kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`
(AWS AMI names also sanitize `k8s_version`'s `+` to `-`; see
`packer/aws/README.md`). Point `kube-compute`'s node modules at it: Proxmox's
`proxmox-control-plane`/`proxmox-node-pool` via `proxmox_template_vm_id` (its
numeric Proxmox VM ID); AWS's `aws-control-plane`/`aws-node-pool` via their
existing `os_image_ami_id` variable. The name is documentation only —
kube-compute performs no compatibility check against it.

## Development

Open in the devcontainer — uses the latest `ghcr.io/bbaliyan/kube-devenv`
image, which already ships Packer. Validate without a live Proxmox/AWS
connection:

```bash
cd packer/proxmox && packer fmt -check . && packer validate .
cd ../aws && packer fmt -check . && packer validate .
cd ../../ansible
ansible-playbook --syntax-check -i localhost, playbook-proxmox.yml
ansible-playbook --syntax-check -i localhost, playbook-aws.yml
```
