#!/usr/bin/env bash
# Runs once per container create (devcontainer.json's postCreateCommand).
set -euo pipefail

# ---- normalize ~/.ssh permissions -------------------------------------------
# The mount is not readonly specifically so this can run. On macOS/Linux/WSL2
# the host directory already has correct perms, so this is a no-op there —
# it's native Windows sources (NTFS bind-mounted via Docker Desktop, if ever
# reached without going through WSL2 as devcontainer.json's own top comment
# says to) this actually matters for: NTFS has no real Unix permission bits,
# so keys mounted from it commonly surface inside the container as too-open
# (or platform-dependent) modes, and ssh/git/Packer's SSH communicator all
# refuse a private key that isn't (at most) 600. Ansible's SSH connections
# during a Packer bake would fail the same way. Guarded with `|| true`:
# ~/.ssh may be empty or contain files this glob doesn't match, and none of
# that should block container creation.
if [ -d ~/.ssh ]; then
  chmod 700 ~/.ssh || true
  find ~/.ssh -maxdepth 1 -type f ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
  find ~/.ssh -maxdepth 1 -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true
fi

# ---- Writes /etc/kube-compute-env.sh, sourced by every shell (interactive
# via ~/.bashrc, non-interactive via BASH_ENV) to load Proxmox credentials
# and derive the Packer-specific PKR_VAR_* equivalents automatically — so
# 'packer build' never needs proxmox_url/proxmox_api_token_id/
# proxmox_api_token_secret set by hand.
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
