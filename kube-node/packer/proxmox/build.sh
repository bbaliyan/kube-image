#!/usr/bin/env bash
# Wrapper for 'packer build': re-derives Proxmox credentials, resolves
# k8s/Cilium/Argo CD versions, and renders the genesis manifests before every
# build.
#
# Credentials are re-derived here (rather than relying on the devcontainer's
# own PKR_VAR_* export, which only runs at shell start) because
# kube-proxmox-login's refresh instruction updates PROXMOX_VE_API_TOKEN in
# the current shell but not an already-exported PKR_VAR_proxmox_*, so a
# same-terminal refresh followed by a bare 'packer build' would otherwise
# fail with a 401 even though PROXMOX_VE_API_TOKEN itself is current.
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

# ---- k8s/Cilium/Argo CD version resolution ----------------------------------
: "${KUBE_PLATFORM_REPO_URL:=https://github.com/bbaliyan/kube-platform.git}"
: "${KUBE_PLATFORM_REVISION:=main}"

# PKR_VAR_* env vars lose to a *.auto.pkrvars.hcl entry of the same name, so
# these three must NOT be set in proxmox.auto.pkrvars.hcl — see README.md.
if [ -z "${PKR_VAR_k8s_version:-}" ] || [ -z "${PKR_VAR_cilium_version:-}" ] || [ -z "${PKR_VAR_argocd_version:-}" ]; then
  platform_versions_url="$(printf '%s' "${KUBE_PLATFORM_REPO_URL}" | sed -E 's#^https://github\.com/#https://raw.githubusercontent.com/#; s#\.git$##')/${KUBE_PLATFORM_REVISION}/platform/platform-versions/values.yaml"
  platform_versions="$(curl -fsSL "${platform_versions_url}")"

  : "${PKR_VAR_k8s_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["k8sVersion"])')}"
  : "${PKR_VAR_cilium_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["ciliumVersion"])')}"
  : "${PKR_VAR_argocd_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["argocdVersion"])')}"
  export PKR_VAR_k8s_version PKR_VAR_cilium_version PKR_VAR_argocd_version
fi

# ---- Genesis manifest render (build host, not the VM being baked) ---------
# Keeps Argo CD's ~1.9 MB of CRDs out of node-bootstrap's cloud-init payload
# (Proxmox's cicustom snippet cap is 1 MiB).
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

packer init "$@" # idempotent, so running it unconditionally removes a manual first-time step

build_args=("$@")
if [ "${PACKER_BUILD_TIMESTAMPS:-0}" = "1" ]; then
  build_args=("-timestamp-ui" "${build_args[@]}")
fi

# Not `exec`: the render_dir cleanup trap only runs on this shell's own exit.
packer build "${build_args[@]}"
