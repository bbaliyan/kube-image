# AWS Packer template

Bakes an RKE2 node image as an AWS AMI, starting from the AlmaLinux OS
Foundation's own published AlmaLinux 10 AMI (owner `764336703387`) — no seed
step needed, unlike Proxmox.

## Prerequisites

- AWS credentials in the standard credential chain (env vars,
  `~/.aws/credentials`, an assumed role, etc.) — same as the AWS CLI/
  Terraform's AWS provider. If your account uses AWS SSO, run
  `aws sso login` yourself first (set `AWS_PROFILE` beforehand if you use a
  named profile). `kube-cloud-login` (from the devcontainer) does not work
  here — it infers the provider from a selected cluster in a `kube-compute`
  consumer repo's `live/<provider>/...` path, and this repo has no cluster
  to select.
- The build host must reach the build instance's private IP on port 22
  directly (Packer connects via a per-build ephemeral keypair and a
  temporary security group scoped to `var.security_group_source_cidrs`,
  required, never `0.0.0.0/0`). This is build-time only — it doesn't change
  how a real cluster node is reached at runtime (still SSM-only, no inbound
  port 22; see "amazon-ssm-agent" below and CLAUDE.md hard constraint #6).
  No direct network path to the build instance at all? Set
  `ssh_interface = "session_manager"` in `template.pkr.hcl` instead — no
  inbound port needed, at the cost of a slower build (~19min vs ~4min,
  measured against an equivalent direct-SSH Proxmox bake, mostly from SSM
  session round-trips and having to re-establish the session after the
  mid-bake reboot).
- `aws` CLI, `helm`, and `python3` with `PyYAML` on the build host.

## Building

Run `packer` from inside this directory — the Ansible provisioner's
playbook path in `template.pkr.hcl` is relative to the current working
directory, not the repo root.

```bash
cp aws.auto.pkrvars.hcl.example aws.auto.pkrvars.hcl
# edit aws.auto.pkrvars.hcl: aws_region, security_group_source_cidrs, and
# subnet_id if your account needs a non-default value
packer init .
./build.sh .
```

This builds an x86_64 AMI (`ami_architecture`/`instance_type`'s defaults).
For arm64, override both as `PKR_VAR_*` env vars, not `-var`/`-var-file`
flags — `build.sh` forwards command-line args to `packer init` too, which
doesn't accept `-var`. `ami_architecture` alone isn't enough either, since
the default `instance_type` (`t3.medium`) can't launch an arm64 AMI:

```bash
PKR_VAR_ami_architecture=arm64 PKR_VAR_instance_type=m7g.medium ./build.sh .
```

Run both commands to produce one AMI of each architecture — the name
includes the architecture, so a same-day build of one doesn't collide with
the other.

`build.sh` also does two things a plain `packer build` can't:

1. Resolves `k8s_version`/`cilium_version`/`argocd_version` from
   kube-platform's `platform/platform-versions/values.yaml`, so the image
   can't silently drift from what Argo CD will run. **Do not** set these
   three in `aws.auto.pkrvars.hcl` — a var-file entry outranks `build.sh`'s
   exported `PKR_VAR_*` and would silently defeat the fetch; export
   `PKR_VAR_cilium_version=...` (etc.) at the shell first for a specific pin.
2. Renders the genesis Cilium/Argo CD manifests (`helm template`) into a
   temp dir, for the Ansible provisioner to copy onto the AMI at
   `/opt/kube-compute/manifests/`. Rendered here rather than at
   `kube-compute` apply time because Argo CD's chart alone is ~1.9 MB with
   CRDs, too large for `node-bootstrap`'s cloud-init payload.

## Base image

`data "amazon-ami" "almalinux10"` in `template.pkr.hcl` matches
`kube-compute`'s `aws-control-plane/data.tf` filter-for-filter (owner
`764336703387`, name `AlmaLinux OS 10*`, `hvm`, `available`, filtered by
architecture) — a data source rather than an inline `source_ami_filter` so
its resolved `.id` can be recorded as the `source-ami-id` tag. Not
load-bearing for image currency: `rke2_bake_common`'s `dnf update -y` fully
updates the instance regardless of which point release the filter resolves.

## amazon-ssm-agent

`rke2_bake_aws` explicitly installs `amazon-ssm-agent` rather than trusting
it's already present. `kube-compute`'s AWS modules use SSM as their *entire*
operator-access path (break-glass shell, verb-scripts, kubeconfig fetch) —
this project's no-inbound-SSH posture means there's no fallback if it's
missing, and their launch-time `systemctl enable --now amazon-ssm-agent`
swallows failure silently.

## Scope: no CAPI/CAPMOX manifest

Unlike the Proxmox template, this AMI does not stage a CAPI/CAPMOX install
manifest — AWS's node pool comes back as a fixed-size ASG, with no
cluster-autoscaler integration yet (`ansible/playbook-aws.yml` sets
`bake_stage_capi_manifests: false`).

## AMI naming

Self-descriptive:
`almalinux10-<architecture>-kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`
(`k8s_version`'s `+` sanitized to `-`, since AWS AMI names disallow it).
`<architecture>` is included so a same-day x86_64 and arm64 build don't
collide — AWS AMI names must be unique per account/region. Point
`kube-compute`'s `aws-control-plane`/`aws-node-pool` modules at the result
via `os_image_ami_id`. The name is documentation only — kube-compute
performs no compatibility check against it.

The AMI/snapshot/build-instance tags also carry `architecture`,
`base-distro`, `build-id` (see "Multi-region replication"), and
`source-ami-id` (the upstream AlmaLinux AMI this build actually resolved
and cloned from, since `most_recent = true` can resolve differently build
to build).

## Multi-region replication

Set `region_replicas` (a list of AWS regions, empty by default) in
`aws.auto.pkrvars.hcl` to copy the finished AMI into other regions — the
`amazon-ebs` builder's native `ami_regions` does the copy and carries the
AMI's tags over, so no separate script is needed:

```hcl
region_replicas = ["us-west-2", "eu-west-1"]
```

Every AMI from one build — the original plus every replica — shares the
same `build-id` tag (`<build-date>-<8-char-uuid>`, e.g.
`2026-08-17-a1b2c3d4`). Consumer Terraform resolves the right regional AMI
by filtering on that tag instead of hardcoding a per-region AMI ID:

```hcl
data "aws_ami" "kube_image" {
  provider    = aws.us-west-2 # whichever region this consumer deploys into
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "tag:build-id"
    values = ["2026-08-17-a1b2c3d4"]
  }
}
```

Destination regions must already be enabled for the account and need
`ec2:CopyImage`/`ec2:CopySnapshot` permissions. `prune-images.sh` needs no
changes for replicas — run it once per region as usual.

## Pruning old builds

Every `packer build` leaves the previous AMI (and its backing snapshot)
around. `prune-images.sh` finds every self-owned AMI tagged `kube-image=true`
for one architecture in a region, keeps the N most recent (by
`CreationDate`), and deregisters the rest, snapshot included. It never
touches AMIs owned by another account, including the AlmaLinux Foundation's
own base images. `--architecture` is required and prunes one architecture
at a time, so pruning x86_64 builds can never delete your only arm64 AMI:

```bash
./prune-images.sh --region us-east-1 --architecture x86_64 --dry-run   # see what would be destroyed
./prune-images.sh --region us-east-1 --architecture x86_64             # keeps 3 by default, asks to confirm
./prune-images.sh --region us-east-1 --architecture arm64 --keep 5 --yes   # non-interactive
```

Separately, `prune-orphaned-iam.sh` sweeps up temporary IAM roles that a
failed Packer cleanup left behind, from the era before this template
stopped self-provisioning IAM roles (see `prune-orphaned-iam.sh`'s own
header for why the leaks happened). Not region-scoped, since IAM isn't:

```bash
./prune-orphaned-iam.sh --dry-run   # see what would be deleted
./prune-orphaned-iam.sh             # only touches roles >60min old, asks to confirm
```

## Accounting tags

`extra_tags` (a `map(string)`, empty by default) is merged onto every AWS
resource a build creates — the AMI, its snapshot, the build instance, and
its volumes:

```hcl
# aws.auto.pkrvars.hcl
extra_tags = {
  CostCenter = "platform"
  Owner      = "name"
}
```

## Validating without a live AWS build

```bash
packer fmt -check .
packer validate .
```
