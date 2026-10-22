#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests for kube-devbox/scripts/acceptance.sh. A stand-in ssh runs the real
# remote script bodies in a local shell, against a fixture directory and
# stand-in docker, git, sudo and sshd commands. No box or network is needed.
# Run from the repository root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ACCEPTANCE_SCRIPT:-$ROOT/kube-devbox/scripts/acceptance.sh}"
WORK="$(mktemp -d)"
LISTENER_PID=""
cleanup() {
  if [[ -n "$LISTENER_PID" ]]; then kill "$LISTENER_PID" 2> /dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
BIN="$WORK/bin"
FIX="$WORK/fixture"
mkdir -p "$BIN" "$FIX/home/dev/.ssh" "$FIX/etc/ssh"
REAL_GREP="$(command -v grep)"
REAL_RM="$(command -v rm)"
DOCKER_LOG="$WORK/docker.log"

# Fixture: a clean box. The host key is expected and must not be reported.
echo "hello" > "$FIX/home/dev/notes.txt"
printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH > "$FIX/etc/ssh/ssh_host_ed25519_key"

# --- stand-ins
cat > "$BIN/ssh" << 'FAKE'
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
if [[ "$args" == *probe@* ]]; then
  [[ "${FAKE_PROBE_LOGIN_FAIL:-0}" == 1 ]] && exit 255
else
  [[ "${FAKE_LOGIN_FAIL:-0}" == 1 ]] && exit 255
fi
PATH="$(dirname "$0"):$PATH"
if [[ "${FAKE_STRIP_SCAN_DONE:-0}" == 1 ]]; then
  bash -c "$last" | grep -v SCAN_DONE
  exit "${PIPESTATUS[0]}"
fi
exec bash -c "$last"
FAKE

cat > "$BIN/docker" << 'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[[ "${1:-}" == run ]] || exit 0
case " $* " in
  *" make test-commit"*)
    [[ "${FAKE_COMMIT_FAIL:-0}" == 1 ]] && exit 1
    [[ -n "${FAKE_COMMIT_SLEEP:-}" ]] && sleep "$FAKE_COMMIT_SLEEP"
    exit 0
    ;;
  *" rm -rf /x/"*)
    src=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == -v ]] && src="${a%%:*}"
      prev="$a"
    done
    "$REAL_RM" -rf "$src/${*##*/x/}"
    exit 0
    ;;
esac
[[ "${FAKE_DOCKER_FAIL:-0}" == 1 ]] && exit 1
exit 0
FAKE

cat > "$BIN/git" << 'FAKE'
#!/usr/bin/env bash
for a; do :; done
case " $* " in *" clone "*) mkdir -p "$a" ;; esac
exit "${FAKE_GIT_RC:-0}"
FAKE

cat > "$BIN/sudo" << 'FAKE'
#!/usr/bin/env bash
[[ "${FAKE_SUDO:-1}" == 1 ]] || exit 1
shift
exec "$@"
FAKE

cat > "$BIN/sshd" << 'FAKE'
#!/usr/bin/env bash
[[ "${FAKE_SSHD_FAIL:-0}" == 1 ]] && exit 1
echo "port 22"
echo "permitrootlogin ${FAKE_PERMITROOT:-no}"
FAKE

# Fails a directory removal on demand, so the container fallback runs.
cat > "$BIN/rm" << 'FAKE'
#!/usr/bin/env bash
if [[ "${FAKE_RM_FAIL:-0}" == 1 && -d "${*: -1}" ]]; then exit 1; fi
exec "$REAL_RM" "$@"
FAKE

# Fails the recursive scan on demand. Other grep calls pass through.
cat > "$BIN/grep" << 'FAKE'
#!/usr/bin/env bash
if [[ "${FAKE_GREP_FAIL:-0}" == 1 && "$*" == *-rIlE* ]]; then exit 2; fi
exec "$REAL_GREP" "$@"
FAKE
chmod +x "$BIN"/*

# --- listeners: one open port, one closed port, for the network rows
PY="$(command -v python3 || command -v python || true)"
if [[ -z "$PY" ]]; then
  echo "tests need python3 for the port listener" >&2
  exit 2
fi
"$PY" -c 'import socket,time
s=socket.socket()
s.bind(("127.0.0.1",0))
s.listen(50)
print(s.getsockname()[1],flush=True)
time.sleep(600)' > "$WORK/open_port" &
LISTENER_PID=$!
CLOSED_PORT="$("$PY" -c 'import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])')"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$WORK/open_port" ]] && break
  sleep 1
done
OPEN_PORT="$(tr -d '\r\n' < "$WORK/open_port")"
[[ -n "$OPEN_PORT" ]] || {
  echo "listener did not start" >&2
  exit 2
}

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
  if (($#)); then args=("$@"); fi
  RC=0
  : > "$DOCKER_LOG"
  OUT=$(env -i PATH="$BIN:$PATH" HOME="$WORK" \
    REAL_GREP="$REAL_GREP" REAL_RM="$REAL_RM" DOCKER_LOG="$DOCKER_LOG" \
    SCAN_ROOTS="$FIX/home $FIX/etc" SCAN_HOMES="$FIX/home/dev" \
    DEVBOX_HOST=box.example.invalid DEVBOX_USER=dev \
    DEVENV_IMAGE=ghcr.io/example/kube-devenv:0.0.0 \
    SPOKE_REPO=https://example.invalid/spoke SPOKE_REF=main \
    ${envs[@]+"${envs[@]}"} bash "$SCRIPT" ${args[@]+"${args[@]}"} 2>&1) || RC=$?
}

ok() {
  PASSED=$((PASSED + 1))
  echo "ok - $1"
}
bad() {
  FAILED=$((FAILED + 1))
  echo "NOT OK - $1"
  printf '%s\n' "${OUT//$'\n'/$'\n'    | }" | sed '1s/^/    | /'
}
expect_rc() { if ((RC == $2)); then ok "$1"; else bad "$1 (exit $RC, wanted $2)"; fi; }
expect_row() { # name, row text, result
  if grep -E "^$2 +$3( |$)" <<< "$OUT" > /dev/null; then ok "$1"; else bad "$1 (row '$2' not $3)"; fi
}
expect_has() { if grep -qE "$2" <<< "$OUT"; then ok "$1"; else bad "$1 ($2 missing)"; fi; }
expect_absent() { if grep -q "$2" <<< "$OUT"; then bad "$1 ($2 appeared)"; else ok "$1"; fi; }
expect_log() { if "$REAL_GREP" -qE -e "$2" "$DOCKER_LOG"; then ok "$1"; else bad "$1 (docker log lacks $2)"; fi; }

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
expect_has "the result counts skipped rows" "^RESULT: PASS \(2 skipped, 0 limited\)"
expect_absent "no host name in the output" "example.invalid"
expect_log "docker run names its container" "run --rm --name acc-docker-"
expect_log "the commit run names its container" "--name acc-commit-"
expect_log "containers are removed on exit" "^rm -f acc-commit-"

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
run "FAKE_PERMITROOT=prohibit-password" --
expect_row "a sshd config that allows root keys fails" "root login refused" FAIL
run "FAKE_SSHD_FAIL=1" --
expect_row "an unreadable sshd config is not a pass" "root login refused" FAIL
run "FAKE_SUDO=0" --
expect_row "no sudo makes the root row LIMITED" "root login refused" LIMITED
expect_rc "a LIMITED row does not fail the run" 0
expect_has "the result counts limited rows" "^RESULT: PASS \(2 skipped, 1 limited\)"
expect_has "the LIMITED note says why" "no sudo -n; only the refusal was proven"

# --- secrets
printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH > "$FIX/home/dev/.ssh/id_ed25519"
echo "machine example" > "$FIX/home/dev/.netrc"
run --
expect_rc "a key on the box fails the run" 1
expect_row "secrets row fails with findings" "no private key or token" FAIL
expect_has "findings list the key path" "/home/dev/.ssh/id_ed25519"
expect_has "findings list the credential file" "/home/dev/.netrc"
expect_absent "findings never show the host key" "ssh_host_ed25519_key"
expect_absent "findings never show contents" "OPENSSH PRIVATE"
"$REAL_RM" -f "$FIX/home/dev/.ssh/id_ed25519" "$FIX/home/dev/.netrc"
run "FAKE_SUDO=0" --
expect_has "a user-only scan is stated" "scan scope: user"
run "FAKE_STRIP_SCAN_DONE=1" --
expect_row "a scan without SCAN_DONE fails" "no private key or token" FAIL
expect_rc "a scan without SCAN_DONE fails the run" 1
run "FAKE_GREP_FAIL=1" --
expect_row "a grep error fails the scan" "no private key or token" FAIL
run "SCAN_ROOTS=$FIX/missing-one $FIX/missing-two" --
expect_row "a scan with no readable root fails" "no private key or token" FAIL

# --- docker and commit tier
run "FAKE_DOCKER_FAIL=1" --
expect_row "docker failure fails the row" "docker runs the pinned image" FAIL
run "FAKE_COMMIT_FAIL=1" --
expect_row "commit tier failure fails the row" "commit tier of a spoke passes" FAIL
expect_rc "commit tier failure fails the run" 1
run "FAKE_GIT_RC=1" --
expect_row "a failed clone fails the commit row" "commit tier of a spoke passes" FAIL
run "COMMIT_TIMEOUT=1" "FAKE_COMMIT_SLEEP=4" --
expect_row "a commit tier that times out fails" "commit tier of a spoke passes" FAIL
expect_log "a timeout still removes the container" "^rm -f acc-commit-"
run "FAKE_RM_FAIL=1" --
expect_row "the commit row still passes when rm fails" "commit tier of a spoke passes" PASS
expect_log "the fallback removes the whole work directory" "-v .*:/x .* rm -rf /x/[A-Za-z0-9._]+$"
if "$REAL_GREP" -q 'rm -rf /x/\*' "$DOCKER_LOG"; then bad "no glob in the docker log"; else ok "no glob in the docker log"; fi

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

# --- isolation rows (targets are local ports, so the real probe code runs)
OPEN_T="127.0.0.1:$OPEN_PORT"
CLOSED_T="127.0.0.1:$CLOSED_PORT"
ISO=("HOME_TARGETS=$CLOSED_T" "INTERNET_TARGET=$OPEN_T" "PROBE_SSH=probe@probe.invalid"
  "DEVBOX_HOST=127.0.0.1" "DEVBOX_PORT=$CLOSED_PORT")
run "${ISO[@]}" -- --isolated
expect_rc "an isolated box passes" 0
expect_row "control row passes" "internet reachable \(control\)" PASS
expect_row "home target 1 is blocked" "home target 1 blocked" PASS
expect_row "a refused probe passes" "non-allowed address refused" PASS
expect_has "nothing is skipped with the flag" "^RESULT: PASS$"
expect_absent "the output has no address" "127.0.0.1"
run "${ISO[@]}" "HOME_TARGETS=$CLOSED_T $OPEN_T" -- --isolated
expect_row "a reachable home target fails" "home target 2 blocked" FAIL
expect_row "a blocked home target still passes" "home target 1 blocked" PASS
expect_rc "a reachable home target fails the run" 1
run "${ISO[@]}" "INTERNET_TARGET=$CLOSED_T" -- --isolated
expect_row "a dead control fails the row" "internet reachable \(control\)" FAIL
expect_row "a dead control fails the home rows" "home target 1 blocked" FAIL
run "${ISO[@]}" "HOME_TARGETS=nonexistent.invalid:445" -- --isolated
expect_row "a lookup error is not a pass" "home target 1 blocked" FAIL
run "${ISO[@]}" "DEVBOX_PORT=$OPEN_PORT" -- --isolated
expect_row "a probe that reaches the box fails" "non-allowed address refused" FAIL
run "${ISO[@]}" "PROBE_CONTROL=$CLOSED_T" -- --isolated
expect_row "a probe with a dead control is not a pass" "non-allowed address refused" FAIL
run "${ISO[@]}" "DEVBOX_HOST=nonexistent.invalid" -- --isolated
expect_row "a probe lookup error is not a pass" "non-allowed address refused" FAIL
run "${ISO[@]}" "FAKE_PROBE_LOGIN_FAIL=1" -- --isolated
expect_row "a probe that cannot log in is not a pass" "non-allowed address refused" FAIL

# --- inputs
run "DEVBOX_HOST=" --
expect_rc "a missing host exits 2" 2
run "DEVBOX_HOST=-oProxyCommand=x" --
expect_rc "a host that starts with a dash exits 2" 2
run "DEVBOX_USER=bad user" --
expect_rc "a bad user exits 2" 2
run "SPOKE_REPO=http://example.invalid/x" --
expect_rc "a spoke URL that is not https exits 2" 2
run "SPOKE_REF=-main" --
expect_rc "a ref that starts with a dash exits 2" 2
run "DEVENV_IMAGE=img;rm -rf /" --
expect_rc "an image with shell characters exits 2" 2
run -- --isolated
expect_rc "--isolated without targets exits 2" 2
run "${ISO[@]}" "PROBE_SSH=" -- --isolated
expect_rc "--isolated without a probe host exits 2" 2
run "${ISO[@]}" "PROBE_SSH=-oProxyCommand=x" -- --isolated
expect_rc "a probe host that starts with a dash exits 2" 2
run "${ISO[@]}" "HOME_TARGETS=   " -- --isolated
expect_rc "blank home targets exit 2" 2
run "${ISO[@]}" "HOME_TARGETS=home;x:1" -- --isolated
expect_rc "a bad target exits 2" 2
run -- --nonsense
expect_rc "an unknown argument exits 2" 2
run -- --help
expect_rc "--help exits 0" 0
if "$REAL_GREP" -qE -e 'SCAN_ROOTS:-.*/var/lib' "$SCRIPT"; then ok "the default scan roots include /var/lib"; else bad "the default scan roots include /var/lib"; fi

# --- missing timeout: a PATH with no timeout and no gtimeout exits 2
NOTIME="$WORK/notime"
mkdir -p "$NOTIME"
for tool in bash env ssh grep sed head tail tr printf cat dirname mktemp; do
  src="$(command -v "$tool" 2> /dev/null || true)"
  if [[ -n "$src" && -x "$src" ]]; then ln -sf "$src" "$NOTIME/$tool"; fi
done
RC=0
OUT=$(env -i PATH="$NOTIME" DEVBOX_HOST=h DEVBOX_USER=dev DEVENV_IMAGE=i SPOKE_REPO=https://x.invalid/y "$NOTIME/bash" "$SCRIPT" 2>&1) || RC=$?
expect_rc "a missing timeout exits 2" 2
expect_has "the message names the macOS fix" "brew install coreutils"

# gtimeout alone is enough. The run passes the tool check and stops at the bad user.
ln -sf "$(command -v sleep)" "$NOTIME/gtimeout"
RC=0
OUT=$(env -i PATH="$NOTIME" DEVBOX_HOST=h DEVBOX_USER="bad user" DEVENV_IMAGE=i SPOKE_REPO=https://x.invalid/y "$NOTIME/bash" "$SCRIPT" 2>&1) || RC=$?
expect_absent "gtimeout satisfies the timeout check" "missing tool: timeout"

echo
echo "$PASSED passed, $FAILED failed"
((FAILED == 0))
