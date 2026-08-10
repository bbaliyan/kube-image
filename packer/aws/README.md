# AWS Packer template

Bakes an RKE2 node image as an AWS AMI, starting from the AlmaLinux OS
Foundation's own published AlmaLinux 10 AMI (owner `764336703387`) — no seed
step needed, unlike Proxmox (AWS already publishes a ready-to-clone-from
base image; Proxmox doesn't).

## Prerequisites

- AWS credentials in the standard credential chain (env vars,
  `~/.aws/credentials`, an assumed role, etc.) — Packer's `amazon-ebs`
  builder reads them the same way the AWS CLI and Terraform's AWS provider
  do. No kube-image-specific credential setup.
- The [Session Manager plugin for the AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed on the build host — the Ansible provisioner connects to the
  build instance over AWS Systems Manager Session Manager
  (`ssh_interface = "session_manager"` in `template.pkr.hcl`), not a direct
  connection to port 22. This means the build instance needs no inbound
  security-group rule at all, matching this project's no-SSH-inbound
  posture elsewhere; the IAM permissions Session Manager itself needs are
  self-provisioned per build (see `template.pkr.hcl`'s
  `temporary_iam_instance_profile_policy_document` — no pre-existing
  instance profile required).
- `aws` CLI, `helm`, and `python3` with `PyYAML` on the build host (same
  requirements `packer/proxmox/build.sh` has, minus `clusterctl` — this
  template doesn't stage a CAPI/CAPMOX install manifest; see "Scope" below).

## Building

Run `packer` from inside this directory (`packer/aws/`) — the Ansible
provisioner's playbook path in `template.pkr.hcl` is relative to the
current working directory, not the repo root.

```bash
cp aws.auto.pkrvars.hcl.example aws.auto.pkrvars.hcl
# edit aws.auto.pkrvars.hcl: aws_region, and subnet_id/ami_architecture if
# your account needs non-default values
packer init .
./build.sh .
```

`k8s_version`/`cilium_version`/`argocd_version` don't need editing —
`build.sh` fetches kube-platform's `platform/platform-versions/values.yaml`
before every build and resolves all three from it, identical to
`packer/proxmox/build.sh`. Do **not** set these three in
`aws.auto.pkrvars.hcl` — a var-file entry outranks `build.sh`'s exported
`PKR_VAR_*`, silently defeating the fetch; `export PKR_VAR_cilium_version=...`
(etc.) at the shell first if you need a specific pin instead of the current
`platform-versions.yaml` value.

`build.sh` also renders the genesis Cilium/Argo CD manifests (`helm
template` against `helm-values/cilium-values.yaml`/`argocd-values.yaml`, at
the resolved versions) into a temp directory on the build host, then the
Ansible provisioner copies the result onto the AMI at
`/opt/kube-compute/manifests/{cilium.yaml,00-argocd.yaml}` — same rendering
approach and same reason as Proxmox's (see `packer/proxmox/README.md`):
keeps Argo CD's ~1.9 MB of CRDs out of `node-bootstrap`'s cloud-init
payload.

## Base image

`source_ami_filter` in `template.pkr.hcl` matches
`kube-compute`'s `aws-control-plane/data.tf` (`data.aws_ami.almalinux10`)
filter-for-filter: owner `764336703387`, name `"AlmaLinux OS 10*"`,
virtualization-type `hvm`, state `available`, filtered by architecture
(`var.ami_architecture`, default `x86_64`). This is not load-bearing for
image currency — `rke2_bake_common`'s `dnf update -y` fully updates the
instance regardless of which AlmaLinux 10 point release the filter resolves
to at build time.

## Scope: no CAPI/CAPMOX manifest

Unlike the Proxmox template, this AMI does **not** stage a CAPI/CAPMOX
install manifest — AWS's node pool comes back as a fixed-size ASG
(`min_size = max_size = desired_capacity`, no scaling policies), with no
cluster-autoscaler integration yet. `ansible/playbook-aws.yml` sets
`bake_stage_capi_manifests: false` accordingly. If AWS ever gets a
Cluster API-driven autoscaler path, this is the flag (and this AMI) to
revisit.

## AMI naming

Self-descriptive, same convention as the Proxmox template's VM template
name: `kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`
(with `k8s_version`'s `+` sanitized to `-`, since AWS AMI names don't allow
`+`). Point `kube-compute`'s `aws-control-plane`/`aws-node-pool` modules at
the resulting AMI ID via their existing `os_image_ami_id` variable. The name
is documentation only — kube-compute performs no compatibility check
against it.

## Pruning old builds

Every `packer build` leaves the previous AMI (and its backing snapshot)
around — Packer has no build history or artifact retention of its own.
`prune-images.sh` finds every self-owned AMI tagged `kube-image=true` in a
region, keeps the N most recent (by AMI `CreationDate`), and deregisters
the rest (deleting each one's backing EBS snapshot too). It never touches
AMIs owned by another account, including the AlmaLinux Foundation's own
published base images this build sources from.

```bash
./prune-images.sh --region us-east-1 --dry-run   # see what would be destroyed
./prune-images.sh --region us-east-1             # keeps 3 by default, asks to confirm
./prune-images.sh --region us-east-1 --keep 5 --yes   # non-interactive
```

## Validating without a live AWS build

```bash
packer fmt -check .
packer validate .
```
