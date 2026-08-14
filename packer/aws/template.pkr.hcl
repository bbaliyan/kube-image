# SPDX-License-Identifier: Apache-2.0
packer {
  required_plugins {
    amazon = {
      # Capped below 1.4.0 (the AWS SDK v2 rewrite): its IAM-instance-profile
      # readiness check fires a DryRun RunInstances with no SubnetId, which
      # always fails as "No default VPC for this user" in an account with no
      # default VPC — regardless of this template's own subnet_id/vpc_id.
      # Unfixed upstream as of v1.8.2; 1.3.10 (last pre-1.4.0) still supports
      # temporary_iam_instance_profile_policy_document without the bug.
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
  # Same slug packer/proxmox/template.pkr.hcl uses. Bump alongside the
  # data.amazon-ami filter below if this project ever moves off AlmaLinux 10.
  distro_slug = "almalinux10"
  # AWS AMI names allow only [A-Za-z0-9()./_-] and spaces (no "+") — the same
  # reason packer/proxmox/template.pkr.hcl sanitizes k8s_version for its own
  # name/tag fields, even though Proxmox's own character set is different.
  image_name = coalesce(var.ami_name, "${local.distro_slug}-kube-image-${local.k8s_version_safe}-${var.cilium_version}-${var.argocd_version}-${local.build_date}")

  # Applied to the AMI, its snapshot, the build instance, and its volumes
  # (var.extra_tags merged in second so it can add but not override).
  # source-ami-id matters because most_recent = true can resolve to a
  # different base AMI on every rebuild — without recording it, there'd be
  # no way to trace a build back to what it actually came from.
  common_tags = merge({
    Name           = local.image_name
    kube-image     = "true"
    k8s-version    = local.k8s_version_safe
    cilium-version = var.cilium_version
    argocd-version = var.argocd_version
    build-date     = local.build_date
    base-distro    = local.distro_slug
    source-ami-id  = data.amazon-ami.almalinux10.id
  }, var.extra_tags)
  snapshot_tags = merge({
    Name       = local.image_name
    kube-image = "true"
  }, var.extra_tags)
}

# Owner 764336703387 is the AlmaLinux OS Foundation's own account — matches
# kube-compute's aws-control-plane/data.tf (data.aws_ami.almalinux10)
# filter-for-filter, so this bakes from the same AMI kube-compute would
# resolve at apply time. A data source rather than an inline
# source_ami_filter so its .id is available for common_tags.source-ami-id —
# an inline filter never exposes what it resolved to.
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

  ami_name        = local.image_name
  ami_description = "RKE2 ${var.k8s_version} / Cilium ${var.cilium_version} / Argo CD ${var.argocd_version}, baked ${local.build_date} from ${data.amazon-ami.almalinux10.id}"
  tags            = local.common_tags
  # Snapshot gets the same base tags so prune-images.sh can find both by
  # kube-image=true without a second lookup.
  snapshot_tags = local.snapshot_tags
  # Without run_tags/run_volume_tags the build instance carries no tags at
  # all while it runs — breaks cost-allocation views that attribute by tag.
  run_tags        = local.common_tags
  run_volume_tags = local.common_tags

  ssh_username = var.ssh_username
  # Direct SSH to the build instance over its private IP, using a
  # Packer-generated ephemeral keypair (temporary_key_pair_type below) that
  # never leaves this one build. This is a build-time-only choice — it does
  # not affect how a real cluster node from the resulting AMI is reached
  # afterward (still SSM-only, no inbound port 22, per CLAUDE.md hard
  # constraint #6); this instance exists only for the duration of one
  # `packer build` and is torn down at the end of it.
  #
  # Switched from ssh_interface = "session_manager" (SSM) because tunneling
  # every Ansible SSH round-trip through an SSM session — and worse,
  # re-establishing that session after rke2_bake_common's mid-play reboot,
  # an AWS API call rather than a cheap TCP retry — measured at ~19min vs
  # ~4min on Proxmox's direct-SSH path for an otherwise-identical bake.
  #
  # "private_ip" rather than Packer's default ("public_ip") because this
  # template never requests a public IP for the build instance (no
  # associate_public_ip_address below) — plenty of networks only ever
  # expose a private IP, reachable from the build host over a VPN or
  # similar, and that's all direct SSH actually needs. If your build host
  # can only reach the instance via a public IP instead (a public subnet +
  # IGW route), set associate_public_ip_address = true and switch this to
  # ssh_interface = "public_ip". If the build host has no direct network
  # path to the instance at all, fall back to
  # ssh_interface = "session_manager" — no inbound port and no build-host
  # reachability needed, at the cost of the slowdown described above.
  ssh_interface = "private_ip"
  # 0.0.0.0/0 is never an acceptable default for an inbound SG rule, so this
  # is a required variable (no default) rather than something this template
  # guesses at — the reachable range is consumer-specific (an environment
  # value that can't be hardcoded here per CLAUDE.md hard constraint #1).
  # Set it in your own gitignored aws.auto.pkrvars.hcl; see
  # aws.auto.pkrvars.hcl.example.
  temporary_security_group_source_cidrs = var.security_group_source_cidrs
  # AlmaLinux 10's OpenSSH drops the legacy "ssh-rsa" (SHA-1) signature
  # algorithm under RHEL's default crypto-policy — the only RSA scheme
  # Packer's SSH client offers for the default RSA temporary keypair, so
  # every publickey attempt fails outright. ed25519 isn't affected.
  temporary_key_pair_type = "ed25519"
  # This build-time keypair is unrelated to whatever key pair (or none, if
  # SSM-only) a consumer later launches an EC2 instance from this AMI with —
  # Packer's temporary key only authenticates its own build session and is
  # never baked into the image's authorized_keys.
}

build {
  name    = "rke2-aws"
  sources = ["source.amazon-ebs.rke2"]

  provisioner "ansible" {
    playbook_file = "../../ansible/playbook-aws.yml"
    user          = var.ssh_username
    # Same reasoning as packer/proxmox/template.pkr.hcl: rke2_bake_common's
    # mid-play reboot (os-prep | reboot after the OS update) kills Packer's
    # own SSH proxy adapter, and ansible.builtin.reboot's reconnect/retry
    # logic can't recover a dead proxy, only a real socket. Now that the
    # build instance is reachable at a real IP directly (ssh_interface =
    # "private_ip" above) instead of only through an SSM tunnel, use_proxy
    # = false lets ansible-playbook dial that IP directly, so a plain TCP
    # retry succeeds once the instance is back up — the same path Proxmox's
    # direct-LAN-IP reconnect uses.
    use_proxy = false
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
      # rke2_bake_aws's amazon-ssm-agent install needs the region to build
      # the correct regional S3 bucket URL.
      "--extra-vars", "aws_region=${var.aws_region}",
    ]
  }
}
