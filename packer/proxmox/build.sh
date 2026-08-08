#!/usr/bin/env bash
# Wrapper for 'packer build' that re-derives PKR_VAR_proxmox_url /
# proxmox_api_token_id / proxmox_api_token_secret from the current
# PROXMOX_VE_ENDPOINT/PROXMOX_VE_API_TOKEN immediately before building.
#
# Why this exists instead of relying on the devcontainer's already-exported
# PKR_VAR_* (see .devcontainer/write-env.sh): that derivation only re-runs
# when a shell starts. kube-proxmox-login's own printed instruction after a
# token refresh is 'source ~/.kube-compute/proxmox' — that updates
# PROXMOX_VE_API_TOKEN in the current shell, but NOT this shell's
# already-exported PKR_VAR_* values (they stay stale from whenever the shell
# started), so a same-terminal token refresh followed by 'packer build'
# directly fails with a 401 even though PROXMOX_VE_API_TOKEN itself is
# current. Re-deriving fresh, right here, right before the real build, makes
# this correct regardless of what got sourced (or wasn't) beforehand.
set -euo pipefail

test -f /root/.kube-compute/proxmox && source /root/.kube-compute/proxmox
test -f /root/.kube-compute/proxmox-endpoint && source /root/.kube-compute/proxmox-endpoint

if [ -n "${PROXMOX_VE_ENDPOINT:-}" ]; then
  export PKR_VAR_proxmox_url="${PROXMOX_VE_ENDPOINT}/api2/json"
fi
if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  export PKR_VAR_proxmox_api_token_id="${PROXMOX_VE_API_TOKEN%%=*}"
  export PKR_VAR_proxmox_api_token_secret="${PROXMOX_VE_API_TOKEN#*=}"
fi

# ---- k8s/Cilium/Argo CD version resolution ---------------------------------
# Same pin kube-compute's component-versions module carries
# (pinned_platform_repo_url/_revision) — each repo keeps its own copy rather
# than sharing config across repos, matching how kube-compute's own
# provider modules already duplicate rather than share.
: "${KUBE_PLATFORM_REPO_URL:=https://github.com/bbaliyan/kube-platform.git}"
: "${KUBE_PLATFORM_REVISION:=main}"

# PKR_VAR_* env vars lose to a *.auto.pkrvars.hcl entry of the same name, so
# k8s_version/cilium_version/argocd_version must NOT be set in
# proxmox.auto.pkrvars.hcl (or its .example) for this fetch to actually take
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

# ---- Genesis manifest render (Packer build host, not the VM being baked) --
# `helm template` here runs on this machine (already has helm and network
# access to the chart repos for the version-resolution fetch above); the VM
# gets only the finished YAML copied in via the ansible provisioner's `copy`
# task (ansible/roles/rke2_bake_common/tasks/main.yml), never helm itself or
# network egress to a chart repo. See README.md for why this moved out of
# kube-compute's node-bootstrap: the live-rendered manifest, embedded whole
# in cloud-init, exceeded Proxmox's 1 MiB cicustom snippet cap on a real
# apply (Argo CD's chart alone renders to ~1.9 MB, CRDs included either way
# --include-crds is set).
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

# Not `exec` here (unlike this script would otherwise prefer): the render_dir
# cleanup trap above only runs on this shell's own exit, which `exec`
# replacing the process image would skip entirely.
packer build "$@"
