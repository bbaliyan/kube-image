#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Acceptance check for a built dev box. Run it from an allowed machine.
# It reads everything site-specific from the environment and prints a table of
# roles and numbers. It never prints an address or the contents of a file.
#
# Exit 0: no row failed. Exit 1: a row failed. Exit 2: a tool or input is missing.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: acceptance.sh [--isolated]

Required environment:
  DEVBOX_HOST      host name or address of the box
  DEVBOX_USER      login user on the box
  DEVENV_IMAGE     pinned kube-devenv image to run on the box, with its tag
  SPOKE_REPO       https URL of a public spoke whose commit tier runs on the box

Optional environment:
  DEVBOX_PORT      SSH port (default 22)
  DEVBOX_SSH_KEY   identity file for the login
  SPOKE_REF        branch, tag or commit of the spoke (default main)
  COMMIT_TIMEOUT   seconds allowed for the commit tier (default 900)

Needed with --isolated:
  HOME_TARGETS     space-separated host:port pairs the box must NOT reach
  INTERNET_TARGET  one host:port the box MUST reach (proves the probe works)
  PROBE_SSH        user@host of a machine at a non-allowed address (optional)

Without --isolated the rows that need the isolated bridge report SKIPPED.
Connect once by hand first, so the box host key is already known.
EOF
}

ISOLATED=0
for arg in "$@"; do
  case "$arg" in
    --isolated) ISOLATED=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "acceptance: unknown argument" >&2
      usage >&2
      exit 2
      ;;
  esac
done

die() {
  echo "acceptance: $*" >&2
  exit 2
}
need_tool() { command -v "$1" > /dev/null || die "missing tool: $1"; }
need_input() { [[ -n "${!1:-}" ]] || die "missing input: $1"; }
valid() { [[ "$2" =~ $3 ]] || die "bad value for $1"; }

need_tool ssh
need_tool timeout
need_tool grep
need_tool sed

DEVBOX_PORT="${DEVBOX_PORT:-22}"
SPOKE_REF="${SPOKE_REF:-main}"
COMMIT_TIMEOUT="${COMMIT_TIMEOUT:-900}"
DEVBOX_SSH_KEY="${DEVBOX_SSH_KEY:-}"
HOME_TARGETS="${HOME_TARGETS:-}"
INTERNET_TARGET="${INTERNET_TARGET:-}"
PROBE_SSH="${PROBE_SSH:-}"

for name in DEVBOX_HOST DEVBOX_USER DEVENV_IMAGE SPOKE_REPO; do need_input "$name"; done
valid DEVBOX_HOST "$DEVBOX_HOST" '^[A-Za-z0-9._:-]+$'
valid DEVBOX_USER "$DEVBOX_USER" '^[a-z_][a-z0-9_-]*$'
valid DEVBOX_PORT "$DEVBOX_PORT" '^[0-9]{1,5}$'
valid DEVENV_IMAGE "$DEVENV_IMAGE" '^[A-Za-z0-9._/:@-]+$'
valid SPOKE_REPO "$SPOKE_REPO" '^https://[A-Za-z0-9._/-]+$'
valid SPOKE_REF "$SPOKE_REF" '^[A-Za-z0-9._/-]+$'
valid COMMIT_TIMEOUT "$COMMIT_TIMEOUT" '^[0-9]{1,5}$'
if [[ -n "$DEVBOX_SSH_KEY" ]]; then valid DEVBOX_SSH_KEY "$DEVBOX_SSH_KEY" '^[A-Za-z0-9._/~-]+$'; fi

if ((ISOLATED)); then
  need_input HOME_TARGETS
  need_input INTERNET_TARGET
  for t in $HOME_TARGETS $INTERNET_TARGET; do valid TARGET "$t" '^[A-Za-z0-9._-]+:[0-9]{1,5}$'; done
  if [[ -n "$PROBE_SSH" ]]; then valid PROBE_SSH "$PROBE_SSH" '^[A-Za-z0-9._@:-]+$'; fi
fi

# ForwardAgent=no keeps the box away from the laptop's keys. A row that needs
# a login must not prompt, so BatchMode stays on.
SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no -p "$DEVBOX_PORT")
if [[ -n "$DEVBOX_SSH_KEY" ]]; then SSH_BASE+=(-i "$DEVBOX_SSH_KEY"); fi

ROWS=()
FAILS=0
FINDINGS=()

add_row() {
  ROWS+=("$(printf '%-36s %-8s %s' "$1" "$2" "$3")")
  if [[ "$2" == FAIL ]]; then FAILS=$((FAILS + 1)); fi
}

# Runs a script on the box over SSH. Arguments reach the script as quoted
# positional parameters, so a value can never become a command.
remote() {
  local limit="$1" script="$2" quoted="" arg
  shift 2
  for arg in "$@"; do quoted+=" $(printf '%q' "$arg")"; done
  printf '%s\n' "$script" | timeout "$limit" ssh "${SSH_BASE[@]}" "$DEVBOX_USER@$DEVBOX_HOST" "bash -s --$quoted" 2> /dev/null
}

# Returns the server's remaining auth methods from "Permission denied (...)".
denied_methods() { sed -nE 's/.*Permission denied \(([^)]*)\).*/\1/p' <<< "$1" | tail -n 1; }

# --- 1 key login works
login_out=$(remote 30 '# row:login
echo ACCEPTANCE_OK' || true)
if grep -qx ACCEPTANCE_OK <<< "$login_out"; then
  LOGIN_OK=1
  add_row "login with key" PASS ""
else
  LOGIN_OK=0
  add_row "login with key" FAIL "no login; later rows that need it fail"
fi

# --- 2 password login refused
pw_out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no -p "$DEVBOX_PORT" \
  -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
  "$DEVBOX_USER@$DEVBOX_HOST" true 2>&1 < /dev/null) && pw_rc=0 || pw_rc=$?
pw_methods=$(denied_methods "$pw_out")
if ((pw_rc == 0)); then
  add_row "password login refused" FAIL "login without a key worked"
elif [[ -z "$pw_methods" ]]; then
  add_row "password login refused" FAIL "no clear refusal; the box may be unreachable"
elif [[ "$pw_methods" == *password* || "$pw_methods" == *keyboard-interactive* ]]; then
  add_row "password login refused" FAIL "the server still offers a password method"
else
  add_row "password login refused" PASS ""
fi

# --- 3 root login refused
root_out=$(ssh "${SSH_BASE[@]}" "root@$DEVBOX_HOST" true 2>&1 < /dev/null) && root_rc=0 || root_rc=$?
if ((root_rc == 0)); then
  add_row "root login refused" FAIL "root login worked"
elif [[ -n "$(denied_methods "$root_out")" ]]; then
  add_row "root login refused" PASS ""
else
  add_row "root login refused" FAIL "no clear refusal; the box may be unreachable"
fi

# --- 4 no private key or token on the box
# The script prints paths only. Host keys under /etc/ssh are expected.
SECRETS_SCRIPT='# row:secrets
set -u
use=""
scope=user
if sudo -n true 2> /dev/null; then
  use="sudo -n"
  scope=root
fi
echo "SCAN_DONE scope=$scope"
# shellcheck disable=SC2086
$use grep -rIlE \
  -e "BEGIN ((RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED) )?PRIVATE KEY" \
  -e "ghp_[A-Za-z0-9]{36}" -e "github_pat_[A-Za-z0-9_]{22,}" \
  -e "glpat-[A-Za-z0-9_-]{20,}" -e "AKIA[0-9A-Z]{16}" -e "xox[baprs]-[A-Za-z0-9-]{10,}" \
  /home /root /opt /srv /tmp /var/tmp /etc 2> /dev/null | grep -vE "^/etc/ssh/ssh_host_" || true
for home in /home/* /root; do
  for f in .git-credentials .netrc .aws/credentials .kube/config .config/gh/hosts.yml .npmrc .pypirc; do
    # shellcheck disable=SC2086
    if $use test -f "$home/$f" 2> /dev/null; then echo "$home/$f"; fi
  done
  # shellcheck disable=SC2086
  if $use test -f "$home/.docker/config.json" 2> /dev/null && $use grep -q "\"auth\"" "$home/.docker/config.json" 2> /dev/null; then
    echo "$home/.docker/config.json"
  fi
done'
if ((LOGIN_OK)); then
  sec_out=$(remote 120 "$SECRETS_SCRIPT" || true)
  if ! grep -q '^SCAN_DONE ' <<< "$sec_out"; then
    add_row "no private key or token" FAIL "the scan did not finish"
  else
    scope=$(sed -nE 's/^SCAN_DONE scope=(.*)$/\1/p' <<< "$sec_out" | head -n 1)
    mapfile -t found < <(grep '^/' <<< "$sec_out" || true)
    if ((${#found[@]} == 0)); then
      add_row "no private key or token" PASS "scan scope: $scope"
    else
      add_row "no private key or token" FAIL "${#found[@]} path(s); scan scope: $scope"
      FINDINGS=("${found[@]}")
    fi
  fi
else
  add_row "no private key or token" FAIL "needs a login"
fi

# --- 5 Docker works
if ((LOGIN_OK)); then
  docker_out=$(remote 400 '# row:docker
set -euo pipefail
docker run --rm "$1" true
echo ACCEPTANCE_OK' "$DEVENV_IMAGE" || true)
  if grep -qx ACCEPTANCE_OK <<< "$docker_out"; then
    add_row "docker runs the pinned image" PASS ""
  else
    add_row "docker runs the pinned image" FAIL "docker run did not finish"
  fi
else
  add_row "docker runs the pinned image" FAIL "needs a login"
fi

# --- 6 commit tier of a spoke inside the box
if ((LOGIN_OK)); then
  commit_out=$(remote $((COMMIT_TIMEOUT + 180)) '# row:commit
set -euo pipefail
repo=$1 ref=$2 image=$3 limit=$4
work=$(mktemp -d)
cleanup() {
  rm -rf "$work" 2> /dev/null || docker run --rm -v "$work:/x" "$image" sh -c "rm -rf /x/*"
  rm -rf "$work"
}
trap cleanup EXIT
git clone --quiet "$repo" "$work/spoke"
git -C "$work/spoke" checkout --quiet "$ref"
timeout "$limit" docker run --rm -v "$work/spoke:/w" -w /w \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0="*" \
  "$image" make test-commit > /dev/null 2>&1
echo ACCEPTANCE_OK' "$SPOKE_REPO" "$SPOKE_REF" "$DEVENV_IMAGE" "$COMMIT_TIMEOUT" || true)
  if grep -qx ACCEPTANCE_OK <<< "$commit_out"; then
    add_row "commit tier of a spoke passes" PASS ""
  else
    add_row "commit tier of a spoke passes" FAIL "make test-commit failed or timed out"
  fi
else
  add_row "commit tier of a spoke passes" FAIL "needs a login"
fi

# --- 7 isolation rows
NET_SCRIPT='# row:net
if timeout 5 bash -c "exec 3<>/dev/tcp/\$0/\$1" "$1" "$2" 2> /dev/null; then echo OPEN; else echo BLOCKED; fi'

net_result() { # target -> prints OPEN, BLOCKED or UNKNOWN
  local out
  out=$(remote 30 "$NET_SCRIPT" "${1%%:*}" "${1##*:}" || true)
  if grep -qx OPEN <<< "$out"; then
    echo OPEN
  elif grep -qx BLOCKED <<< "$out"; then
    echo BLOCKED
  else
    echo UNKNOWN
  fi
}

if ((ISOLATED)); then
  if ((LOGIN_OK)); then
    control=$(net_result "$INTERNET_TARGET")
    if [[ "$control" == OPEN ]]; then
      add_row "internet reachable (control)" PASS ""
    else
      add_row "internet reachable (control)" FAIL "without it a blocked result proves nothing"
    fi
    i=0
    for target in $HOME_TARGETS; do
      i=$((i + 1))
      if [[ "$control" != OPEN ]]; then
        add_row "home target $i blocked" FAIL "control failed"
        continue
      fi
      case "$(net_result "$target")" in
        BLOCKED) add_row "home target $i blocked" PASS "" ;;
        OPEN) add_row "home target $i blocked" FAIL "the box opened a connection" ;;
        *) add_row "home target $i blocked" FAIL "no answer from the box" ;;
      esac
    done
  else
    add_row "internet reachable (control)" FAIL "needs a login"
    add_row "home targets blocked" FAIL "needs a login"
  fi

  if [[ -z "$PROBE_SSH" ]]; then
    add_row "non-allowed address refused" SKIPPED "no PROBE_SSH given"
  else
    probe_ssh=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no "$PROBE_SSH")
    probe_login=$(printf '%s\n' '# row:probelogin
echo ACCEPTANCE_OK' | timeout 30 "${probe_ssh[@]}" "bash -s --" 2> /dev/null || true)
    if ! grep -qx ACCEPTANCE_OK <<< "$probe_login"; then
      add_row "non-allowed address refused" FAIL "the probe host did not log in"
    else
      probe_out=$(printf '%s\n' "$NET_SCRIPT" | timeout 30 "${probe_ssh[@]}" \
        "bash -s -- $(printf '%q' "$DEVBOX_HOST") $(printf '%q' "$DEVBOX_PORT")" 2> /dev/null || true)
      if grep -qx BLOCKED <<< "$probe_out"; then
        add_row "non-allowed address refused" PASS ""
      elif grep -qx OPEN <<< "$probe_out"; then
        add_row "non-allowed address refused" FAIL "the probe reached the SSH port"
      else
        add_row "non-allowed address refused" FAIL "no answer from the probe host"
      fi
    fi
  fi
else
  add_row "home targets blocked" SKIPPED "needs --isolated"
  add_row "non-allowed address refused" SKIPPED "needs --isolated"
fi

printf '%-36s %-8s %s\n' ROW RESULT NOTE
printf '%s\n' "${ROWS[@]}"
if ((${#FINDINGS[@]} > 0)); then
  echo
  echo "Paths found on the box (names only):"
  printf '  %s\n' "${FINDINGS[@]}"
fi
echo
if ((FAILS > 0)); then
  echo "RESULT: FAIL ($FAILS row(s) failed)"
  exit 1
fi
echo "RESULT: PASS"
