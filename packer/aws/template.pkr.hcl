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
  # Tunnels the build SSH session through AWS Systems Manager Session Manager
  # instead of a direct connection to port 22 — no inbound security-group rule
  # needed on the build instance, matching this project's no-SSH-inbound
  # posture elsewhere (CLAUDE.md hard constraint #6's control-plane
  # abstraction, and kube-compute's aws-control-plane/aws-node-pool modules,
  # which already grant instances AmazonSSMManagedInstanceCore for the same
  # reason). Requires the session-manager-plugin binary on the build host —
  # see README.md.
  ssh_interface = "session_manager"
  # AlmaLinux 10's OpenSSH drops the legacy "ssh-rsa" (SHA-1) signature
  # algorithm under RHEL's default crypto-policy — the only RSA scheme
  # Packer's SSH client offers for the default RSA temporary keypair, so
  # every publickey attempt fails outright. ed25519 isn't affected.
  temporary_key_pair_type = "ed25519"
  # Self-provisions a throwaway instance profile scoped to exactly the
  # Session Manager permissions the build needs, so building doesn't depend
  # on a pre-existing, account-specific instance profile ARN (which would be
  # an environment value this public repo can't hardcode). Destroyed by
  # Packer automatically at the end of the build, same lifecycle as the
  # instance itself.
  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ssm:UpdateInstanceInformation",
        "ec2messages:GetMessages",
        "ec2messages:AcknowledgeMessage",
      ]
      Resource = ["*"]
    }
  }
}

build {
  name    = "rke2-aws"
  sources = ["source.amazon-ebs.rke2"]

  provisioner "ansible" {
    playbook_file = "../../ansible/playbook-aws.yml"
    user          = var.ssh_username
    # packer/proxmox/template.pkr.hcl sets use_proxy = false here because
    # rke2_bake_common's mid-play reboot (os-prep | reboot after the OS
    # update) kills Packer's own SSH proxy adapter, and ansible-playbook can
    # only recover by dialing the VM's real, LAN-reachable IP directly. That
    # fallback doesn't exist on AWS with ssh_interface = "session_manager"
    # above — there is no direct IP path to the build instance to fall back
    # to (that's the point of routing over SSM instead of opening port 22),
    # so use_proxy stays at its default (true): Packer's own SSH proxy is
    # the only path in, and its reconnect logic re-establishes the SSM
    # tunnel after the reboot. Confirmed working on a real build, just slow
    # by default — see rke2_bake_common's bake_reboot_connect_timeout/
    # bake_reboot_post_delay (tuned down in playbook-aws.yml).
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
      # rke2_bake_aws's amazon-ssm-agent install needs the region to build
      # the correct regional S3 bucket URL.
      "--extra-vars", "aws_region=${var.aws_region}",
    ]
  }
}
