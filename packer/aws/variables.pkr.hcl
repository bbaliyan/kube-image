# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  type        = string
  description = "AWS region to build the AMI in, e.g. us-east-1."
}

variable "instance_type" {
  type        = string
  default     = "c8a.medium"
  description = "EC2 instance type for the build instance. Unrelated to the instance type a consumer later launches from the resulting AMI. Non-burstable: 'dnf update -y' is CPU/disk-bound, not network-bound, and is the dominant cost of a build."
}

variable "subnet_id" {
  type        = string
  default     = null
  description = "Subnet the build instance launches into. Defaults to null (the account's default VPC) — set explicitly if there isn't one, or to build in a specific subnet."
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "VPC the build instance launches into. Defaults to null, which only works with a default VPC — Packer can't infer vpc_id from subnet_id alone. Find it with: aws ec2 describe-subnets --subnet-ids <subnet_id> --query 'Subnets[0].VpcId' --output text"
}

variable "ami_architecture" {
  type        = string
  default     = "x86_64"
  description = "CPU architecture to build for — must match instance_type's supported architecture (e.g. arm64 for Graviton types like c8g.medium)."
}

variable "ami_name" {
  type        = string
  default     = null
  description = "Overrides the self-descriptive computed AMI name (see README.md's \"AMI naming\"). Leave unset in normal use."
}

variable "build_id_override" {
  type        = string
  default     = env("BUILD_ID")
  description = "Uniqueness suffix for the AMI name/build-id tag (see README.md's \"AMI naming\"), read from the BUILD_ID env var — a CI pipeline's own run identifier, if set. Empty by default, which auto-generates an 8-char random one instead. env() is only valid in a variable default, hence this indirection rather than reading it directly in locals."
}

variable "region_replicas" {
  type        = list(string)
  default     = []
  description = "Additional AWS regions to copy the built AMI into (see README.md's \"Multi-region replication\"). Do not include aws_region itself. Each destination region needs ec2:CopyImage/CopySnapshot permissions and must already be enabled for the account."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags (e.g. cost-center/owner) merged onto every resource this build creates. Can't override this template's own fixed tags."
}

variable "ssh_username" {
  type        = string
  default     = "ec2-user"
  description = "SSH user Packer and the Ansible provisioner both connect as — AWS's standard default for RHEL-family AMIs."
}

variable "k8s_version" {
  type        = string
  description = "RKE2 release string to bake, e.g. v1.36.1+rke2r1. Resolved automatically by build.sh — do not set in aws.auto.pkrvars.hcl, it silently outranks build.sh's fetch."
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version, genesis-installed into /opt/kube-compute/manifests/cilium.yaml. Resolved automatically by build.sh — same do-not-set caveat as k8s_version."
}

variable "argocd_version" {
  type        = string
  description = "Argo CD Helm chart version, genesis-installed into /opt/kube-compute/manifests/00-argocd.yaml. Resolved automatically by build.sh — same do-not-set caveat as k8s_version."
}

variable "rendered_manifests_dir" {
  type        = string
  description = "Directory containing the pre-rendered cilium.yaml/00-argocd.yaml to copy onto the AMI. Always set by build.sh — no default, so a bare 'packer build' fails loudly instead of baking a stale manifest."
}
