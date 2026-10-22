#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Checks of the devbox_common role that need no Docker, no systemd and no cloud.
# They run in the kube-devenv image as part of make test-commit.
#   - the playbook parses
#   - the role holds no key, token or site address
#   - the sshd drop-in renders with the hardening settings
#   - the firewall script fails closed and renders only what launch input allows
#   - the tailscale script uses the key once and removes it
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ansible_dir="${here}/../ansible"
role="${ansible_dir}/roles/devbox_common"
fw="${role}/files/devbox-firewall-apply"
ts="${role}/files/devbox-tailscale-up"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
expect() { # name, command...
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
expect_not() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}

# --- the playbook parses
expect "playbook syntax" bash -c "cd '${ansible_dir}' && ansible-playbook --syntax-check -i localhost, playbook-proxmox.yml"

# --- no key, token or site value in the role
expect_not "role holds no private key or token" \
  grep -rIEq 'BEGIN [A-Z ]*PRIVATE KEY|tskey-|ghp_|github_pat_|glpat-' "$role"
expect_not "role holds no private-range address" \
  grep -rIEq '(^|[^0-9.])(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)' "$role"

# --- the sshd drop-in
ssh_out="${work}/sshd-00-devbox.conf"
ansible localhost -c local -m ansible.builtin.template \
  -a "src=${role}/templates/sshd-00-devbox.conf.j2 dest=${ssh_out} mode=0600" \
  -e devbox_user=almalinux >/dev/null 2>&1 || true
for line in \
  "PasswordAuthentication no" \
  "KbdInteractiveAuthentication no" \
  "PermitRootLogin no" \
  "PubkeyAuthentication yes" \
  "AuthenticationMethods publickey" \
  "AllowUsers almalinux" \
  "AllowAgentForwarding yes"; do
  expect "sshd drop-in has: ${line}" grep -qx "$line" "$ssh_out"
done
expect_not "sshd drop-in does not allow passwords" grep -qiE '^PasswordAuthentication +yes' "$ssh_out"

# --- the firewall script
fwenv="${work}/launch.env"
printf 'DEVBOX_SSH_SOURCES="192.0.2.10 192.0.2.11/32 2001:db8::5"\nDEVBOX_TAILNET_INTERFACE=tailscale0\n' >"$fwenv"
rules="$(DEVBOX_LAUNCH_ENV="$fwenv" bash "$fw" --print)"
expect "firewall: default drop" grep -q 'policy drop' <<<"$rules"
expect "firewall: v4 sources on port 22" grep -q 'ip saddr { 192.0.2.10,192.0.2.11/32 } tcp dport 22 accept' <<<"$rules"
expect "firewall: v6 source on port 22" grep -q 'ip6 saddr { 2001:db8::5 } tcp dport 22 accept' <<<"$rules"
expect "firewall: tailnet interface on port 22" grep -q 'iifname "tailscale0" tcp dport 22 accept' <<<"$rules"
expect "firewall: loopback allowed" grep -q 'iif "lo" accept' <<<"$rules"
expect "firewall: replies allowed" grep -q 'ct state established,related accept' <<<"$rules"
expect_not "firewall: no unrestricted port 22" grep -qE '^ *tcp dport 22' <<<"$rules"

closed="$(bash "$fw" --closed --print)"
expect "firewall closed: default drop" grep -q 'policy drop' <<<"$closed"
expect_not "firewall closed: no SSH rule" grep -q 'dport 22' <<<"$closed"

expect_not "firewall: missing input exits non-zero" env DEVBOX_LAUNCH_ENV="${work}/absent.env" bash "$fw" --print
missing="$(DEVBOX_LAUNCH_ENV="${work}/absent.env" bash "$fw" --print 2>/dev/null || true)"
expect_not "firewall: missing input opens no SSH" grep -q 'dport 22' <<<"$missing"

printf 'DEVBOX_SSH_SOURCES="192.0.2.10 ; rm -rf /"\n' >"${work}/evil.env"
expect_not "firewall: bad source exits non-zero" env DEVBOX_LAUNCH_ENV="${work}/evil.env" bash "$fw" --print
evil="$(DEVBOX_LAUNCH_ENV="${work}/evil.env" bash "$fw" --print 2>/dev/null || true)"
expect_not "firewall: bad source opens no SSH" grep -q 'dport 22' <<<"$evil"

printf 'DEVBOX_SSH_SOURCES="192.0.2.10"\nDEVBOX_TAILNET_INTERFACE="ts0; drop"\n' >"${work}/badif.env"
expect_not "firewall: bad interface exits non-zero" env DEVBOX_LAUNCH_ENV="${work}/badif.env" bash "$fw" --print
badif="$(DEVBOX_LAUNCH_ENV="${work}/badif.env" bash "$fw" --print 2>/dev/null || true)"
expect_not "firewall: bad interface opens no SSH" grep -q 'dport 22' <<<"$badif"

expect_not "firewall: unknown option exits non-zero" bash "$fw" --nope

if command -v nft >/dev/null 2>&1; then
  expect "firewall: nft accepts the rules" bash -c "DEVBOX_LAUNCH_ENV='${fwenv}' bash '$fw' --print | nft -c -f -"
else
  echo "skip firewall: nft is not installed here; the container test runs it"
fi

# --- the tailscale script, with a stand-in tailscale command
stub="${work}/bin"
mkdir -p "$stub"
cat >"${stub}/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}"
[ "${STUB_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB
chmod +x "${stub}/tailscale"
export STUB_LOG="${work}/tailscale.log"

keyfile="${work}/authkey"
: >"$STUB_LOG"
expect "tailscale: no key file exits zero" env PATH="${stub}:${PATH}" DEVBOX_TAILSCALE_KEY_FILE="${work}/none" DEVBOX_LAUNCH_ENV="$fwenv" bash "$ts"
expect_not "tailscale: no key file does not call tailscale" test -s "$STUB_LOG"

printf 'DEVBOX_TAILNET_TAG=tag:dev\n' >"${work}/ts.env"
printf 'placeholder-not-a-key' >"$keyfile"
expect "tailscale: runs with a key" env PATH="${stub}:${PATH}" DEVBOX_TAILSCALE_KEY_FILE="$keyfile" DEVBOX_LAUNCH_ENV="${work}/ts.env" bash "$ts"
expect "tailscale: key file is removed after use" test ! -e "$keyfile"
expect "tailscale: sets the tag" grep -q -- '--advertise-tags=tag:dev' "$STUB_LOG"
expect "tailscale: reads the key from the file" grep -q -- "--auth-key=file:${keyfile}" "$STUB_LOG"
expect "tailscale: no exit node" grep -q -- '--advertise-exit-node=false' "$STUB_LOG"
expect "tailscale: no routes" grep -q -- '--accept-routes=false' "$STUB_LOG"
expect_not "tailscale: no subnet routes advertised" grep -q -- '--advertise-routes' "$STUB_LOG"
expect_not "tailscale: the key itself is not in the arguments" grep -q 'placeholder-not-a-key' "$STUB_LOG"

printf 'placeholder-not-a-key' >"$keyfile"
: >"$STUB_LOG"
printf 'DEVBOX_TAILNET_TAG="tag:dev; id"\n' >"${work}/badtag.env"
expect_not "tailscale: bad tag exits non-zero" env PATH="${stub}:${PATH}" DEVBOX_TAILSCALE_KEY_FILE="$keyfile" DEVBOX_LAUNCH_ENV="${work}/badtag.env" bash "$ts"
expect_not "tailscale: bad tag does not call tailscale" test -s "$STUB_LOG"

printf 'DEVBOX_TAILNET_TAG=tag:dev\n' >"${work}/ts.env"
expect_not "tailscale: a failing join exits non-zero" env STUB_FAIL=1 PATH="${stub}:${PATH}" DEVBOX_TAILSCALE_KEY_FILE="$keyfile" DEVBOX_LAUNCH_ENV="${work}/ts.env" bash "$ts"
expect "tailscale: a failing join keeps the key file for a retry" test -e "$keyfile"

# --- units
for unit in "$role"/files/*.service "$role"/files/*.timer; do
  name="$(basename "$unit")"
  expect "unit ${name} has a Unit section" grep -q '^\[Unit\]' "$unit"
  # The prune service is started by its timer, so only the others need an Install section.
  if [ "$name" != "devbox-docker-prune.service" ]; then
    expect "unit ${name} has an Install section" grep -q '^\[Install\]' "$unit"
  fi
done

echo "static role checks: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
