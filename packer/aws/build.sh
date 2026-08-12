#!/usr/bin/env bash
# Wrapper for 'packer build' that renders the genesis Cilium/Argo CD
# manifests and resolves k8s_version/cilium_version/argocd_version from
# kube-platform's platform-versions.yaml before every build — the AWS
# counterpart of packer/proxmox/build.sh, minus the Proxmox-only credential
# derivation and CAPI/CAPMOX manifest render (AWS's node pool comes back as
# a fixed-size ASG with no cluster-autoscaler integration yet, so there is
# no AWS equivalent of CAPMOX to stage — see ansible/playbook-aws.yml's
# bake_stage_capi_manifests: false).
#
# AWS credentials are NOT derived here, unlike Proxmox's PKR_VAR_proxmox_*
# re-export: Packer's amazon-ebs builder reads the standard AWS credential
# chain (env vars, ~/.aws/credentials, an assumed role, instance metadata)
# directly, the same way the AWS CLI and Terraform's AWS provider do — there
# is no kube-image-specific token to refresh the way Proxmox's short-lived
# API token needs.
set -euo pipefail

# ---- k8s/Cilium/Argo CD version resolution ---------------------------------
# Same pin kube-compute's component-versions module carries
# (pinned_platform_repo_url/_revision) — each repo keeps its own copy rather
# than sharing config across repos, matching packer/proxmox/build.sh.
: "${KUBE_PLATFORM_REPO_URL:=https://github.com/bbaliyan/kube-platform.git}"
: "${KUBE_PLATFORM_REVISION:=main}"

# PKR_VAR_* env vars lose to a *.auto.pkrvars.hcl entry of the same name, so
# k8s_version/cilium_version/argocd_version must NOT be set in
# aws.auto.pkrvars.hcl (or its .example) for this fetch to actually take
# effect — see README.md. Already-exported PKR_VAR_* (e.g. a manual override
# at the shell) still wins over this fetch, since each export below is
# conditional on the variable being unset.
if [ -z "${PKR_VAR_k8s_version:-}" ] || [ -z "${PKR_VAR_cilium_version:-}" ] || [ -z "${PKR_VAR_argocd_version:-}" ]; then
  platform_versions_url="$(printf '%s' "${KUBE_PLATFORM_REPO_URL}" | sed -E 's#^https://github\.com/#https://raw.githubusercontent.com/#; s#\.git$##')/${KUBE_PLATFORM_REVISION}/platform/platform-versions/values.yaml"
  platform_versions="$(curl -fsSL "${platform_versions_url}")"

  : "${PKR_VAR_k8s_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["k8sVersion"])')}"
  : "${PKR_VAR_cilium_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["ciliumVersion"])')}"
  : "${PKR_VAR_argocd_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["argocdVersion"])')}"
  export PKR_VAR_k8s_version PKR_VAR_cilium_version PKR_VAR_argocd_version
fi

# ---- Genesis manifest render (Packer build host, not the instance being
# baked) — identical rendering to packer/proxmox/build.sh; see that script's
# comment for why this runs here rather than live at kube-compute apply
# time (Argo CD's chart renders to ~1.9 MB with CRDs, well past Proxmox's
# 1 MiB cicustom snippet cap; kept identical on AWS for one consistent bake
# story across providers rather than a second, divergent one).
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

helm template cilium cilium \
  --repo https://helm.cilium.io/ \
  --version "${PKR_VAR_cilium_version}" \
  --namespace kube-system \
  --include-crds \
  -f helm-values/cilium-values.yaml \
  >"${render_dir}/cilium.yaml"

{
  cat <<-'EOF'
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: argocd
	---
	EOF
  helm template argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --version "${PKR_VAR_argocd_version}" \
    --namespace argocd \
    --include-crds \
    -f helm-values/argocd-values.yaml
} >"${render_dir}/00-argocd.yaml"

export PKR_VAR_rendered_manifests_dir="${render_dir}"

# packer init is idempotent (no-op if template.pkr.hcl's required_plugins are
# already installed), so running it unconditionally on every build removes a
# manual first-time step (README's "packer init .") without adding real cost.
packer init "$@"

# -timestamp-ui timestamps every output line, so a slow step is visible
# while it's happening. Off by default (CI doesn't need it) — opt in with
# PACKER_BUILD_TIMESTAMPS=1 ./build.sh .
build_args=("$@")
if [ "${PACKER_BUILD_TIMESTAMPS:-0}" = "1" ]; then
  build_args=("-timestamp-ui" "${build_args[@]}")
fi

# Not `exec` here (unlike this script would otherwise prefer): the render_dir
# cleanup trap above only runs on this shell's own exit, which `exec`
# replacing the process image would skip entirely.
packer build "${build_args[@]}"
