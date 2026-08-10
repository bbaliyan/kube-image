# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  type        = string
  description = "AWS region to build the AMI in, e.g. us-east-1. Standard AWS credential chain (env vars, ~/.aws/credentials, an assumed role, etc.) supplies the credentials themselves — Packer's amazon-ebs builder reads them the same way the AWS CLI/Terraform's AWS provider do, nothing kube-image-specific to configure."
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for the build/bake instance. Only needs to be large enough to run the bake role's dnf update + RKE2 install in reasonable time — unrelated to the instance type a consumer later launches from the resulting AMI."
}

variable "subnet_id" {
  type        = string
  default     = null
  description = "Subnet the build instance launches into. Defaults to null, which leaves subnet selection to Packer/AWS's own default-VPC behavior (matches this project's default-VPC fallback used elsewhere, e.g. kube-compute's node modules) — set explicitly if the build host's account has no default VPC, or to build in a specific subnet."
}

variable "ami_architecture" {
  type        = string
  default     = "x86_64"
  description = "CPU architecture to filter the AlmaLinux 10 base AMI on and to build for — must match instance_type's supported architecture (e.g. \"arm64\" for Graviton instance types like m7g.medium). Same filter dimension kube-compute's aws-control-plane data.tf derives dynamically from the launch instance_type; kept as a plain variable here since a Packer build only ever targets one architecture per invocation, not a runtime-selected one."
}

variable "ami_name" {
  type        = string
  default     = null
  description = "Overrides the self-descriptive AMI name (kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>) computed automatically from k8s_version/cilium_version/argocd_version. Leave unset in normal use — only needed if AWS's AMI-name character restrictions ever reject the computed name for a future version string, or to disambiguate a rebuild on the same day."
}

variable "ssh_username" {
  type        = string
  default     = "almalinux"
  description = "SSH user Packer's communicator and the Ansible provisioner both connect as — the AlmaLinux OS Foundation's published AMIs default cloud-init user, same account name Proxmox's seed template uses."
}

variable "k8s_version" {
  type        = string
  description = "RKE2 release string to bake, e.g. v1.36.1+rke2r1. Same neutral naming convention as kube-compute's k8s_version variable — no distro-specific variable name. Resolved automatically by build.sh from kube-platform's platform/platform-versions/values.yaml (k8sVersion) — do not set this in aws.auto.pkrvars.hcl (an auto.pkrvars.hcl entry outranks build.sh's PKR_VAR_k8s_version export, silently defeating the live resolution); override at the shell instead if you need a specific pin."
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version. Genesis-installs this pinned chart directly (see helm-values/cilium-values.yaml) — not RKE2's own rke2-cilium HelmChart CRD — into /opt/kube-compute/manifests/cilium.yaml on the AMI, for node-bootstrap to apply at first boot. Resolved automatically by build.sh from kube-platform's platform/platform-versions/values.yaml (ciliumVersion); same do-not-set-in-aws.auto.pkrvars.hcl caveat as k8s_version applies."
}

variable "argocd_version" {
  type        = string
  description = "Argo CD Helm chart version. Genesis-installs this pinned chart (see helm-values/argocd-values.yaml) into /opt/kube-compute/manifests/00-argocd.yaml on the AMI; only needs to produce *a* working Argo CD — kube-platform's own bootstrap/templates/argocd-app.yaml carries the consumer's chosen ongoing version afterward. Resolved automatically by build.sh from kube-platform's platform/platform-versions/values.yaml (argocdVersion); same do-not-set-in-aws.auto.pkrvars.hcl caveat as k8s_version applies."
}

variable "rendered_manifests_dir" {
  type        = string
  description = "Local directory (on the Packer build host) containing the pre-rendered cilium.yaml/00-argocd.yaml to copy onto the AMI. Always set by build.sh (a fresh mktemp -d per build, rendered via helm template immediately before invoking packer build) — not meant to be set by hand; there is no default so a bare 'packer build' (bypassing build.sh) fails loudly instead of silently baking a stale or missing manifest."
}
