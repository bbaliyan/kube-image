#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runs the devbox_common role inside an AlmaLinux 10 container, then asserts the
# result. The container has no systemd and no Docker daemon, so the role runs with
# its service, image-pull and template-cleanup switches off. Those parts are only
# covered by a real image build.
#
# This needs a Docker daemon. Inside the kube-devenv image there is none, so the
# script skips there; run it on a host with Docker: make test-devbox-container
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ansible_dir="${here}/../ansible"
image="${DEVBOX_TEST_IMAGE:-almalinux:10}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ "${DEVBOX_REQUIRE_DOCKER:-0}" = "1" ]; then
    echo "FAIL: this test needs a Docker daemon" >&2
    exit 1
  fi
  echo "skip: no Docker daemon here. Run this on a host with Docker: make test-devbox-container"
  exit 0
fi

# Mounting from a Docker-in-Docker path would not work, so copy the role in with a pipe.
name="devbox-role-test-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
# NET_ADMIN lets nft dry-run the rules. It only reaches this container's own network.
docker run -d --cap-add NET_ADMIN --name "$name" "$image" sleep 3600 >/dev/null
tar -C "$ansible_dir" -c . | docker exec -i "$name" bash -c 'mkdir -p /ansible && tar -C /ansible -x'

docker exec -i "$name" bash -s <<'INNER'
set -euo pipefail
dnf -y -q install ansible-core python3-dnf sudo shadow-utils >/dev/null
useradd -m almalinux
cat >/ansible/inventory <<INV
localhost ansible_connection=local
INV
cd /ansible
ansible-playbook -i inventory playbook-proxmox.yml -l localhost \
  -e devbox_manage_services=false \
  -e devbox_pull_devenv_image=false \
  -e devbox_clean_for_template=false
# Second run: the role must not change anything.
ansible-playbook -i inventory playbook-proxmox.yml -l localhost \
  -e devbox_manage_services=false \
  -e devbox_pull_devenv_image=false \
  -e devbox_clean_for_template=false | tee /tmp/second-run.log
grep -qE 'changed=0 ' /tmp/second-run.log || { echo "FAIL: second run changed something"; exit 1; }

fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

ssh-keygen -A >/dev/null
sshd_out="$(/usr/sbin/sshd -T -C user=almalinux,host=h,addr=192.0.2.1)"
check "sshd: passwords off" "grep -qx 'passwordauthentication no' <<<\"\$sshd_out\""
check "sshd: keyboard-interactive off" "grep -qx 'kbdinteractiveauthentication no' <<<\"\$sshd_out\""
check "sshd: root login off" "grep -qx 'permitrootlogin no' <<<\"\$sshd_out\""
check "sshd: public keys on" "grep -qx 'pubkeyauthentication yes' <<<\"\$sshd_out\""
check "sshd: agent forwarding on" "grep -qx 'allowagentforwarding yes' <<<\"\$sshd_out\""
check "sshd: only publickey" "grep -qx 'authenticationmethods publickey' <<<\"\$sshd_out\""
check "sshd: one allowed user" "grep -qx 'allowusers almalinux' <<<\"\$sshd_out\""
check "sshd: config is valid" "/usr/sbin/sshd -t"

check "docker CLI installed" "rpm -q docker-ce-cli"
check "docker engine installed" "rpm -q docker-ce"
check "tailscale installed" "rpm -q tailscale"
check "login user is in the docker group" "id -nG almalinux | tr ' ' '\n' | grep -qx docker"
check "dnf-automatic is security-only" "grep -qx 'upgrade_type = security' /etc/dnf/automatic.conf"
check "dnf-automatic applies updates" "grep -qx 'apply_updates = yes' /etc/dnf/automatic.conf"
check "prune timer installed" "test -f /etc/systemd/system/devbox-docker-prune.timer"

# Not enrolled: no tailscale state, no auth key.
check "tailscale is not enrolled" "! test -e /var/lib/tailscale/tailscaled.state"
check "no tailscale auth key on disk" "! test -e /etc/devbox/tailscale-authkey"

# The firewall renders and nft accepts it.
dnf -y -q install nftables >/dev/null
printf 'DEVBOX_SSH_SOURCES="192.0.2.10 2001:db8::5"\n' >/tmp/launch.env
rules="$(DEVBOX_LAUNCH_ENV=/tmp/launch.env /usr/local/sbin/devbox-firewall-apply --print)"
check "firewall: nft accepts the rules" "DEVBOX_LAUNCH_ENV=/tmp/launch.env /usr/local/sbin/devbox-firewall-apply --print | nft -c -f -"
check "firewall: SSH only from the named source" "grep -q 'ip saddr { 192.0.2.10 } tcp dport 22 accept' <<<\"\$rules\""
check "firewall: default drop" "grep -q 'policy drop' <<<\"\$rules\""
check "firewall closed rules accepted by nft" "/usr/local/sbin/devbox-firewall-apply --closed --print | nft -c -f -"

# No private key or token anywhere the role wrote.
check "no private key under /etc/devbox or /home" "! grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY' /etc/devbox /home /root"
check "no token-like file in /etc/devbox" "! grep -rIlE 'tskey-|ghp_|github_pat_' /etc/devbox"
check "no authorized_keys baked" "! test -s /home/almalinux/.ssh/authorized_keys"

exit "$fail"
INNER
