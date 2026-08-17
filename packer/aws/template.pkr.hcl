# SPDX-License-Identifier: Apache-2.0
packer {
  required_plugins {
    amazon = {
      # >= 1.4.0 (AWS SDK v2 rewrite) fires a DryRun RunInstances with no
      # SubnetId during its IAM-instance-profile check, which always fails
      # as "No default VPC for this user" in an account with no default VPC.
      # Unfixed upstream as of v1.8.2.
      version = ">= 1.3.3, < 1.4.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  build_date       = formatdate("YYYY-MM-DD", timestamp())
  k8s_version_safe = replace(var.k8s_version, "+", "-")
  distro_slug      = "almalinux10" # bump alongside the data.amazon-ami filter below
  # var.build_id_override (BUILD_ID env var) wins when set; otherwise an
  # 8-char random suffix, so two builds on the same day never collide —
  # including two manual devcontainer builds run minutes apart.
  build_suffix = var.build_id_override != "" ? var.build_id_override : substr(uuidv4(), 0, 8)
  # Identifies one build across every region it's replicated to. See
  # README.md's "Multi-region replication".
  build_id = "${local.build_date}-${local.build_suffix}"
  # var.ami_architecture is folded in so a same-day x86_64 and arm64 build
  # don't compute the same name — AWS AMI names must be unique per
  # account/region. build_suffix for the same reason across same-day reruns.
  image_name = coalesce(var.ami_name, "${local.distro_slug}-${var.ami_architecture}-kube-image-${local.k8s_version_safe}-${var.cilium_version}-${var.argocd_version}-${local.build_date}-${local.build_suffix}")

  # var.extra_tags merged in last so it can add but not override.
  common_tags = merge({
    Name           = local.image_name
    kube-image     = "true"
    k8s-version    = local.k8s_version_safe
    cilium-version = var.cilium_version
    argocd-version = var.argocd_version
    build-date     = local.build_date
    build-id       = local.build_id
    base-distro    = local.distro_slug
    architecture   = var.ami_architecture
    source-ami-id  = data.amazon-ami.almalinux10.id
  }, var.extra_tags)
  snapshot_tags = merge({
    Name         = local.image_name
    kube-image   = "true"
    build-id     = local.build_id
    architecture = var.ami_architecture
  }, var.extra_tags)
}

# Owner 764336703387 is the AlmaLinux OS Foundation's own account — matches
# kube-compute's aws-control-plane/data.tf filter-for-filter. A data source
# rather than an inline source_ami_filter so .id is available for the
# source-ami-id tag.
data "amazon-ami" "almalinux10" {
  region      = var.aws_region
  owners      = ["764336703387"]
  most_recent = true
  filters = {
    name                = "AlmaLinux OS 10*"
    architecture        = var.ami_architecture
    virtualization-type = "hvm"
    state               = "available"
  }
}

source "amazon-ebs" "rke2" {
  region        = var.aws_region
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  source_ami    = data.amazon-ami.almalinux10.id

  # gp3 over the AMI's default gp2 — gp3's baseline 3,000 IOPS/125 MiB/s is
  # available immediately (no gp2 burst-bucket ramp-up), which matters here
  # since 'dnf update -y' is disk-write-heavy across many small RPM
  # transactions. device_name assumes AlmaLinux's published AMI roots at
  # /dev/sda1, standard for RHEL-family cloud images — if a build ever fails
  # here with a device-name mismatch, confirm via
  # `aws ec2 describe-images --image-ids <ami-id> --query 'Images[0].RootDeviceName'`.
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ami_name        = local.image_name
  ami_description = "RKE2 ${var.k8s_version} / Cilium ${var.cilium_version} / Argo CD ${var.argocd_version}, baked ${local.build_date} from ${data.amazon-ami.almalinux10.id}"
  tags            = local.common_tags
  snapshot_tags   = local.snapshot_tags
  # Copies the finished AMI, tags included, into each listed region. Empty
  # by default. See README.md's "Multi-region replication".
  ami_regions = var.region_replicas
  # Without these the build instance carries no tags while it runs, which
  # breaks cost-allocation views that attribute by tag.
  run_tags        = local.common_tags
  run_volume_tags = local.common_tags

  ssh_username = var.ssh_username
  # Direct SSH over the build instance's private IP via a per-build
  # ephemeral keypair — build-time only, doesn't affect how a real cluster
  # node is reached afterward (still SSM-only, no inbound 22; CLAUDE.md hard
  # constraint #6). Switched from ssh_interface = "session_manager" because
  # tunneling every Ansible round-trip through SSM — and re-establishing
  # that session after the mid-bake reboot via an AWS API call rather than a
  # cheap TCP retry — measured ~19min vs ~4min for an equivalent
  # direct-SSH Proxmox bake. No direct network path to the instance at all?
  # Set associate_public_ip_address + ssh_interface = "public_ip", or fall
  # back to ssh_interface = "session_manager" for the slower but portless path.
  ssh_interface = "private_ip"
  # No default: the reachable range is consumer-specific and 0.0.0.0/0 is
  # never an acceptable default for an inbound rule (CLAUDE.md hard
  # constraint #1). Set in aws.auto.pkrvars.hcl.
  temporary_security_group_source_cidrs = var.security_group_source_cidrs
  # AlmaLinux 10's OpenSSH drops the legacy ssh-rsa (SHA-1) signature under
  # RHEL's default crypto-policy — the only RSA scheme Packer's default
  # temporary keypair offers. ed25519 isn't affected.
  temporary_key_pair_type = "ed25519"
}

build {
  name    = "rke2-aws"
  sources = ["source.amazon-ebs.rke2"]

  provisioner "ansible" {
    playbook_file = "../../ansible/playbook-aws.yml"
    user          = var.ssh_username
    # rke2_bake_common's mid-play reboot kills Packer's SSH proxy adapter;
    # ansible.builtin.reboot's reconnect logic can't recover a dead proxy,
    # only a real socket. use_proxy = false dials the instance's real IP
    # directly instead, so a plain TCP retry succeeds once it's back up.
    use_proxy = false
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
      "--extra-vars", "aws_region=${var.aws_region}", # rke2_bake_aws needs it for the ssm-agent RPM URL
    ]
  }
}
