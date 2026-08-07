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

exec packer build "$@"
