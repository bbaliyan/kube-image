# SPDX-License-Identifier: Apache-2.0
packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.3"
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
  # AWS AMI names allow only [A-Za-z0-9()./_-] and spaces (no "+") — the same
  # reason packer/proxmox/template.pkr.hcl sanitizes k8s_version for its own
  # name/tag fields, even though Proxmox's own character set is different.
  image_name = coalesce(var.ami_name, "kube-image-${local.k8s_version_safe}-${var.cilium_version}-${var.argocd_version}-${local.build_date}")
}

source "amazon-ebs" "rke2" {
  region        = var.aws_region
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  source_ami_filter {
    # Owner 764336703387 is the AlmaLinux OS Foundation's own AWS account,
    # name filter "AlmaLinux OS 10*", virtualization-type "hvm", state
    # "available" — matches kube-compute's aws-control-plane/data.tf
    # (data.aws_ami.almalinux10) filter-for-filter, so the base image this
    # bakes from is exactly the one kube-compute's own AWS AMI lookup would
    # otherwise resolve to at apply time.
    owners      = ["764336703387"]
    most_recent = true
    filters = {
      name                = "AlmaLinux OS 10*"
      architecture        = var.ami_architecture
      virtualization-type = "hvm"
      state               = "available"
    }
  }

  ami_name        = local.image_name
  ami_description = "RKE2 ${var.k8s_version} / Cilium ${var.cilium_version} / Argo CD ${var.argocd_version}, baked ${local.build_date}"
  tags = {
    Name           = local.image_name
    kube-image     = "true"
    k8s-version    = local.k8s_version_safe
    cilium-version = var.cilium_version
    argocd-version = var.argocd_version
    build-date     = local.build_date
  }
  # Snapshot inherits the same tags so prune-images.sh (which deregisters the
  # AMI and deletes its backing snapshot together) can find both by the same
  # kube-image=true tag without a second lookup.
  snapshot_tags = {
    Name       = local.image_name
    kube-image = "true"
  }

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
    # the only path in, and its reconnect logic is relied on to
    # re-establish the SSM tunnel after the reboot. UNVERIFIED against a
    # real AWS build (no AWS connectivity in this environment) — if the
    # proxy adapter turns out not to recover from the mid-bake reboot the
    # way Proxmox's did, that's the first thing to revisit.
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}",
      "--extra-vars", "rendered_manifests_dir=${var.rendered_manifests_dir}",
      # rke2_bake_aws's amazon-ssm-agent install needs the region to build
      # the correct regional S3 bucket URL.
      "--extra-vars", "aws_region=${var.aws_region}",
    ]
  }
}
