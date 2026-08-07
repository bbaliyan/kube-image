#!/usr/bin/env bash
# Writes /etc/kube-compute-env.sh, sourced by every shell (interactive via
# ~/.bashrc, non-interactive via BASH_ENV) to load Proxmox credentials and
# derive the Packer-specific PKR_VAR_* equivalents automatically — so
# 'packer build' never needs proxmox_url/proxmox_api_token_id/
# proxmox_api_token_secret set by hand.
set -euo pipefail

cat >/etc/kube-compute-env.sh <<'EOF'
test -f /root/.kube-compute/proxmox && source /root/.kube-compute/proxmox
test -f /root/.kube-compute/proxmox-endpoint && source /root/.kube-compute/proxmox-endpoint

# Packer's proxmox-clone builder wants a full API URL plus a separately-split
# token ID/secret, unlike bpg/proxmox's Terraform provider (which parses the
# combined PROXMOX_VE_API_TOKEN itself) — derive both PKR_VAR_* equivalents
# here so 'packer build' picks them up with zero manual input, the same way
# packer/proxmox/seed/ already gets PROXMOX_VE_ENDPOINT/PROXMOX_VE_API_TOKEN
# for free. Re-evaluated on every shell start, so a token refreshed via
# kube-proxmox-login (which rewrites ~/.kube-compute/proxmox) is picked up by
# any new terminal without editing this file.
if [ -n "${PROXMOX_VE_ENDPOINT:-}" ]; then
  export PKR_VAR_proxmox_url="${PROXMOX_VE_ENDPOINT}/api2/json"
fi
if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  export PKR_VAR_proxmox_api_token_id="${PROXMOX_VE_API_TOKEN%%=*}"
  export PKR_VAR_proxmox_api_token_secret="${PROXMOX_VE_API_TOKEN#*=}"
fi
EOF

grep -q 'kube-compute-env.sh' ~/.bashrc || echo 'source /etc/kube-compute-env.sh' >>~/.bashrc
