#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for kube-devbox/scripts/acceptance.sh with a stand-in ssh.
# Run from the repository root. No box, network or Docker is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ACCEPTANCE_SCRIPT:-$ROOT/kube-devbox/scripts/acceptance.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# The stand-in ssh answers by the row marker in the script it receives.
# Behaviour comes from FAKE_* variables.
cat > "$WORK/bin/ssh" << 'FAKE'
#!/usr/bin/env bash
args="$*"
last="${*: -1}"
if [[ "${FAKE_SSH_ALWAYS:-}" == fail ]]; then exit 255; fi
if [[ "${FAKE_SSH_ALWAYS:-}" == succeed ]]; then exit 0; fi
if [[ "$args" == *PubkeyAuthentication=no* ]]; then
  echo "${FAKE_PW_ERR-user@host: Permission denied (publickey).}" >&2
  exit "${FAKE_PW_RC:-255}"
fi
if [[ "$args" == *root@* ]]; then
  echo "${FAKE_ROOT_ERR-root@host: Permission denied (publickey).}" >&2
  exit "${FAKE_ROOT_RC:-255}"
fi
script=$(cat)
set -- $(eval "echo ${last#bash -s --}")
host="${1:-}"
case "$script" in
  '# row:login'*)
    [[ "${FAKE_LOGIN_FAIL:-0}" == 1 ]] && exit 255
    echo ACCEPTANCE_OK
    ;;
  '# row:probelogin'*)
    [[ "${FAKE_PROBE_LOGIN_FAIL:-0}" == 1 ]] && exit 255
    echo ACCEPTANCE_OK
    ;;
  '# row:secrets'*)
    echo "SCAN_DONE scope=${FAKE_SCOPE:-root}"
    [[ -n "${FAKE_SECRET_PATHS:-}" ]] && printf '%s\n' $FAKE_SECRET_PATHS
    exit 0
    ;;
  '# row:docker'*)
    [[ "${FAKE_DOCKER_FAIL:-0}" == 1 ]] && exit 1
    echo ACCEPTANCE_OK
    ;;
  '# row:commit'*)
    [[ "${FAKE_COMMIT_FAIL:-0}" == 1 ]] && exit 1
    echo ACCEPTANCE_OK
    ;;
  '# row:net'*)
    if [[ "$args" == *"${FAKE_PROBE_TARGET:-no-probe}"* ]]; then
      if [[ "${FAKE_PROBE_OPEN:-0}" == 1 ]]; then echo OPEN; else echo BLOCKED; fi
    elif [[ " ${FAKE_OPEN_HOSTS:-} " == *" $host "* ]]; then
      echo OPEN
    else
      echo BLOCKED
    fi
    ;;
  *) exit 99 ;;
esac
FAKE
chmod +x "$WORK/bin/ssh"

PASSED=0
FAILED=0
OUT=""
RC=0

run() { # env assignments... -- script args...
  local envs=() args=()
  while (($#)) && [[ "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  shift || true
  args=("$@")
  RC=0
  OUT=$(env -i PATH="$WORK/bin:$PATH" HOME="$WORK" \
    DEVBOX_HOST=box.example.invalid DEVBOX_USER=dev \
    DEVENV_IMAGE=ghcr.io/example/kube-devenv:0.0.0 \
    SPOKE_REPO=https://example.invalid/spoke SPOKE_REF=main \
    "${envs[@]}" bash "$SCRIPT" "${args[@]}" 2>&1) || RC=$?
}

ok() {
  PASSED=$((PASSED + 1))
  echo "ok - $1"
}
bad() {
  FAILED=$((FAILED + 1))
  echo "NOT OK - $1"
  printf '%s
' "${OUT//$'
'/$'
'    | }" | sed '1s/^/    | /'
}
expect_rc() { if ((RC == $2)); then ok "$1"; else bad "$1 (exit $RC, wanted $2)"; fi; }
expect_row() { # name, row text, result
  if grep -E "^$2 +$3( |$)" <<< "$OUT" > /dev/null; then ok "$1"; else bad "$1 (row '$2' not $3)"; fi
}
expect_absent() { if grep -q "$2" <<< "$OUT"; then bad "$1 ($2 appeared)"; else ok "$1"; fi; }

# --- all good, not isolated
run --
expect_rc "a good box passes" 0
expect_row "login row passes" "login with key" PASS
expect_row "password row passes" "password login refused" PASS
expect_row "root row passes" "root login refused" PASS
expect_row "secrets row passes" "no private key or token" PASS
expect_row "docker row passes" "docker runs the pinned image" PASS
expect_row "commit row passes" "commit tier of a spoke passes" PASS
expect_row "home rows are skipped without the flag" "home targets blocked" SKIPPED
expect_row "probe row is skipped without the flag" "non-allowed address refused" SKIPPED
expect_absent "no host name in the output" "example.invalid"

# --- password and root
run "FAKE_PW_RC=0" --
expect_rc "a password login that works fails the run" 1
expect_row "password row fails when the login worked" "password login refused" FAIL
run "FAKE_PW_ERR=user@host: Permission denied (publickey,password)." --
expect_row "a server that offers a password fails" "password login refused" FAIL
run "FAKE_PW_ERR=user@host: Permission denied (publickey,keyboard-interactive)." --
expect_row "keyboard-interactive counts as a password" "password login refused" FAIL
run "FAKE_PW_ERR=ssh: connect to host box port 22: Connection refused" --
expect_row "no refusal message is not a pass" "password login refused" FAIL
run "FAKE_ROOT_RC=0" --
expect_row "root login that works fails" "root login refused" FAIL
run "FAKE_ROOT_ERR=ssh: connect to host box port 22: Connection timed out" --
expect_row "a root timeout is not a pass" "root login refused" FAIL

# --- secrets
run "FAKE_SECRET_PATHS=/home/dev/.ssh/id_ed25519 /home/dev/.netrc" --
expect_rc "a key on the box fails the run" 1
expect_row "secrets row fails with findings" "no private key or token" FAIL
if grep -q "/home/dev/.netrc" <<< "$OUT"; then ok "findings list the path"; else bad "findings list the path"; fi
run "FAKE_SCOPE=user" --
if grep -q "scan scope: user" <<< "$OUT"; then ok "a user-only scan is stated"; else bad "a user-only scan is stated"; fi

# --- docker and commit tier
run "FAKE_DOCKER_FAIL=1" --
expect_row "docker failure fails the row" "docker runs the pinned image" FAIL
run "FAKE_COMMIT_FAIL=1" --
expect_row "commit tier failure fails the row" "commit tier of a spoke passes" FAIL
expect_rc "commit tier failure fails the run" 1

# --- login failure
run "FAKE_LOGIN_FAIL=1" --
expect_row "no login fails the login row" "login with key" FAIL
expect_row "rows that need a login fail with it" "docker runs the pinned image" FAIL
expect_rc "no login fails the run" 1

# --- broken stand-ins never give a pass
run "FAKE_SSH_ALWAYS=fail" --
expect_rc "an ssh that always fails fails the run" 1
if grep -qE " PASS( |$)" <<< "$OUT"; then bad "an ssh that always fails gives no PASS"; else ok "an ssh that always fails gives no PASS"; fi
run "FAKE_SSH_ALWAYS=succeed" --
expect_rc "an ssh that always succeeds with no output fails the run" 1
if grep -qE "^(login with key|docker runs|commit tier|no private key) .* PASS" <<< "$OUT"; then bad "silent success gives no PASS"; else ok "silent success gives no PASS"; fi

# --- isolation rows
ISO=("HOME_TARGETS=home-a.invalid:445 home-b.invalid:22" "INTERNET_TARGET=net.invalid:443" "FAKE_OPEN_HOSTS=net.invalid")
run "${ISO[@]}" -- --isolated
expect_rc "an isolated box passes" 0
expect_row "control row passes" "internet reachable \(control\)" PASS
expect_row "home target 1 is blocked" "home target 1 blocked" PASS
expect_row "home target 2 is blocked" "home target 2 blocked" PASS
expect_row "no probe host gives SKIPPED" "non-allowed address refused" SKIPPED
run "${ISO[@]}" "FAKE_OPEN_HOSTS=net.invalid home-b.invalid" -- --isolated
expect_row "a reachable home target fails" "home target 2 blocked" FAIL
expect_row "a blocked home target still passes" "home target 1 blocked" PASS
expect_rc "a reachable home target fails the run" 1
run "${ISO[@]}" "FAKE_OPEN_HOSTS=home-a.invalid" -- --isolated
expect_row "a dead control fails the row" "internet reachable \(control\)" FAIL
expect_row "a dead control fails the home rows" "home target 1 blocked" FAIL
expect_absent "the output has no host name from the targets" "home-a.invalid"

PROBE=("PROBE_SSH=probe@probe.invalid" "FAKE_PROBE_TARGET=probe@probe.invalid")
run "${ISO[@]}" "${PROBE[@]}" -- --isolated
expect_row "a refused probe passes" "non-allowed address refused" PASS
run "${ISO[@]}" "${PROBE[@]}" "FAKE_PROBE_OPEN=1" -- --isolated
expect_row "a probe that reaches the box fails" "non-allowed address refused" FAIL
run "${ISO[@]}" "${PROBE[@]}" "FAKE_PROBE_LOGIN_FAIL=1" -- --isolated
expect_row "a probe that cannot log in is not a pass" "non-allowed address refused" FAIL

# --- inputs
run "DEVBOX_HOST=" --
expect_rc "a missing host exits 2" 2
run "DEVBOX_USER=bad user" --
expect_rc "a bad user exits 2" 2
run "SPOKE_REPO=http://example.invalid/x" --
expect_rc "a spoke URL that is not https exits 2" 2
run "DEVENV_IMAGE=img;rm -rf /" --
expect_rc "an image with shell characters exits 2" 2
run -- --isolated
expect_rc "--isolated without targets exits 2" 2
run "HOME_TARGETS=home;x:1" "INTERNET_TARGET=net.invalid:443" -- --isolated
expect_rc "a bad target exits 2" 2
run -- --nonsense
expect_rc "an unknown argument exits 2" 2
run -- --help
expect_rc "--help exits 0" 0

echo
echo "$PASSED passed, $FAILED failed"
((FAILED == 0))
