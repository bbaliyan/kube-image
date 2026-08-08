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

# ---- Build target detection -------------------------------------------------
# Packer has no HCL-level "build target" variable — target selection is via
# the CLI's own '-only=<build_name>.<source_type>.<source_name>' flag (see
# README.md), now that this directory has two build blocks (template.pkr.hcl's
# "rke2-proxmox" and autoscaler-worker.pkr.hcl's "proxmox-autoscaler-worker").
# This wrapper inspects "$@" for that flag to decide which version-resolution
# and manifest-render logic below actually needs to run for the target being
# built — both targets now resolve clusterctl's CAPI/CAPMOX/CAPRKE2 version
# pins (control-plane to render capi-install.yaml, autoscaler-worker for its
# own template naming), but only the autoscaler-worker target stages RKE2's
# own air-gap release artifacts, and only the control-plane target actually
# writes capi-install.yaml onto the image.
build_target="control-plane"
only_flag_given=false
for arg in "$@"; do
  case "$arg" in
    -only=*autoscaler-worker*) build_target="autoscaler-worker" ;;
  esac
  case "$arg" in
    -only=*) only_flag_given=true ;;
  esac
done

# Preserve this script's pre-existing default behavior (build only the
# rke2-proxmox target) now that a second build block exists in this
# directory — without an explicit -only, Packer would otherwise build BOTH
# blocks on every invocation, silently doubling build time/requiring
# clusterctl for everyone. Callers that want the new target pass their own
# -only explicitly (see README.md), which skips this default entirely.
if ! $only_flag_given; then
  set -- -only=rke2-proxmox.proxmox-clone.rke2 "$@"
fi

# ---- k8s/Cilium/Argo CD/CAPI version resolution -----------------------------
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
#
# CAPI/CAPMOX/CAPRKE2 pins are now resolved for every build, not just the
# autoscaler-worker target: the control-plane (rke2-proxmox) target needs
# them to render capi-install.yaml below (bootstrap.sh applies that manifest
# from the control-plane/genesis node, which boots from THIS image — not the
# worker one, so the render has to happen here now, not only for
# autoscaler-worker). The autoscaler-worker target still needs these purely
# for its own template name/description (autoscaler-worker.pkr.hcl's
# autoscaler_image_name) even though it no longer stages capi-install.yaml
# itself.
capi_versions_needed=false
if [ -z "${PKR_VAR_capi_core_version:-}" ] || [ -z "${PKR_VAR_capmox_version:-}" ] || [ -z "${PKR_VAR_caprke2_version:-}" ]; then
  capi_versions_needed=true
fi

if [ -z "${PKR_VAR_k8s_version:-}" ] || [ -z "${PKR_VAR_cilium_version:-}" ] || [ -z "${PKR_VAR_argocd_version:-}" ] || $capi_versions_needed; then
  platform_versions_url="$(printf '%s' "${KUBE_PLATFORM_REPO_URL}" | sed -E 's#^https://github\.com/#https://raw.githubusercontent.com/#; s#\.git$##')/${KUBE_PLATFORM_REVISION}/platform/platform-versions/values.yaml"
  platform_versions="$(curl -fsSL "${platform_versions_url}")"

  : "${PKR_VAR_k8s_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["k8sVersion"])')}"
  : "${PKR_VAR_cilium_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["ciliumVersion"])')}"
  : "${PKR_VAR_argocd_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["argocdVersion"])')}"
  export PKR_VAR_k8s_version PKR_VAR_cilium_version PKR_VAR_argocd_version

  # CAPI/CAPMOX/CAPRKE2 pins only exist in platform-versions.yaml once
  # kube-platform's own version-pin task lands them (capiCoreVersion/
  # capmoxVersion/caprke2Version) — fetched/required for every build now
  # (see the comment above this block for why both targets need them).
  : "${PKR_VAR_capi_core_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["capiCoreVersion"])')}"
  : "${PKR_VAR_capmox_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["capmoxVersion"])')}"
  : "${PKR_VAR_caprke2_version:=$(printf '%s' "${platform_versions}" | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["caprke2Version"])')}"
  export PKR_VAR_capi_core_version PKR_VAR_capmox_version PKR_VAR_caprke2_version
fi

# ---- CAPI/CAPMOX/CAPRKE2 install manifest render (control-plane only) -----
# Four separate 'clusterctl generate provider' invocations — a single
# combined call across --core/--infrastructure/--bootstrap/--control-plane is
# unconfirmed to exist (no clusterctl doc example combines them). If a
# combined call is later confirmed to work against the real clusterctl
# binary, collapse these four calls into one and delete this comment.
render_capi_manifests() {
  local out_dir="$1" # e.g. "$render_dir/capi"
  mkdir -p "$out_dir"

  clusterctl generate provider --core "cluster-api:${PKR_VAR_capi_core_version}" \
    --write-to "${out_dir}/00-capi-core.yaml"
  clusterctl generate provider --infrastructure "ionos-cloud-proxmox:${PKR_VAR_capmox_version}" \
    --write-to "${out_dir}/01-capmox.yaml"
  clusterctl generate provider --bootstrap "rke2:${PKR_VAR_caprke2_version}" \
    --write-to "${out_dir}/02-caprke2-bootstrap.yaml"
  clusterctl generate provider --control-plane "rke2:${PKR_VAR_caprke2_version}" \
    --write-to "${out_dir}/03-caprke2-control-plane.yaml"

  cat "${out_dir}"/*.yaml >"${out_dir}/capi-install.yaml"
}

# ---- RKE2 air-gap artifact staging (autoscaler-worker only) ---------------
# Filenames and the INSTALL_RKE2_ARTIFACT_PATH convention match RKE2's own
# airgap docs, not invented here.
stage_rke2_airgap_artifacts() {
  local out_dir="$1" # e.g. "$render_dir/rke2-artifacts"
  local k8s_version="$2"
  mkdir -p "$out_dir"

  curl -sfL "https://github.com/rancher/rke2/releases/download/${k8s_version}/rke2.linux-amd64.tar.gz" \
    -o "${out_dir}/rke2.linux-amd64.tar.gz"
  curl -sfL "https://github.com/rancher/rke2/releases/download/${k8s_version}/rke2-images.linux-amd64.tar.zst" \
    -o "${out_dir}/rke2-images.linux-amd64.tar.zst"
  curl -sfL "https://github.com/rancher/rke2/releases/download/${k8s_version}/sha256sum-amd64.txt" \
    -o "${out_dir}/sha256sum-amd64.txt"
  curl -sfL "https://get.rke2.io" -o "${out_dir}/install.sh"
}

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

# capi-install.yaml is rendered for the control-plane target now, not the
# autoscaler-worker one: bootstrap.sh's `kubectl apply -f
# /opt/kube-compute/manifests/capi-install.yaml` step runs on the
# control-plane/genesis node, which always boots from THIS image — never
# from the autoscaler-worker image — so that's the image that needs the file
# staged on it. rendered_capi_manifests_dir carries a safe empty-string
# default (variables.pkr.hcl) for the case where this ever isn't set.
if [ "$build_target" = "control-plane" ]; then
  render_capi_manifests "${render_dir}/capi"
  export PKR_VAR_rendered_capi_manifests_dir="${render_dir}/capi"
fi

# RKE2's own air-gap release artifacts are still autoscaler-worker only — the
# pre-existing rke2-proxmox/control-plane target does a normal online RKE2
# install (rke2_bake_common's own install task) and never needs these.
# rendered_rke2_artifacts_dir carries a safe empty-string default
# (variables.pkr.hcl) for exactly this case.
if [ "$build_target" = "autoscaler-worker" ]; then
  stage_rke2_airgap_artifacts "${render_dir}/rke2-artifacts" "${PKR_VAR_k8s_version}"
  export PKR_VAR_rendered_rke2_artifacts_dir="${render_dir}/rke2-artifacts"
fi

# Not `exec` here (unlike this script would otherwise prefer): the render_dir
# cleanup trap above only runs on this shell's own exit, which `exec`
# replacing the process image would skip entirely.
packer build "$@"
