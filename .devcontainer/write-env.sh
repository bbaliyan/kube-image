#!/usr/bin/env bash
# Runs once per container create (devcontainer.json's postCreateCommand).
set -euo pipefail

# ---- normalize ~/.ssh permissions -------------------------------------------
# No-op on macOS/Linux/WSL2 (already correct perms). Matters for a
# native-Windows NTFS bind mount, which has no real Unix permission bits —
# ssh/git/Packer's SSH communicator all refuse a private key that isn't (at
# most) 600. `|| true`: ~/.ssh may be empty, which shouldn't block creation.
if [ -d ~/.ssh ]; then
  chmod 700 ~/.ssh || true
  find ~/.ssh -maxdepth 1 -type f ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
  find ~/.ssh -maxdepth 1 -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true
fi

# ---- Writes /etc/kube-compute-env.sh, sourced by every shell (interactive
# via ~/.bashrc, non-interactive via BASH_ENV) to load Proxmox credentials
# and derive the Packer-specific PKR_VAR_* equivalents automatically.
cat >/etc/kube-compute-env.sh <<'EOF'
test -f /root/.kube-compute/proxmox && source /root/.kube-compute/proxmox
test -f /root/.kube-compute/proxmox-endpoint && source /root/.kube-compute/proxmox-endpoint

# Packer's proxmox-clone builder wants a full API URL plus a separately-split
# token ID/secret, unlike bpg/proxmox's Terraform provider. Re-evaluated on
# every shell start, so a token refreshed via kube-proxmox-login is picked
# up by any new terminal without editing this file.
if [ -n "${PROXMOX_VE_ENDPOINT:-}" ]; then
  export PKR_VAR_proxmox_url="${PROXMOX_VE_ENDPOINT}/api2/json"
fi
if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
  export PKR_VAR_proxmox_api_token_id="${PROXMOX_VE_API_TOKEN%%=*}"
  export PKR_VAR_proxmox_api_token_secret="${PROXMOX_VE_API_TOKEN#*=}"
fi
EOF

grep -q 'kube-compute-env.sh' ~/.bashrc || echo 'source /etc/kube-compute-env.sh' >>~/.bashrc
