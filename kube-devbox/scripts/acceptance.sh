#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Acceptance check for a built dev box. Run it from an allowed machine.
# It reads everything site-specific from the environment and prints a table of
# roles and numbers. It never prints an address or the contents of a file.
# It runs on bash 3.2 (macOS). On macOS, install GNU coreutils for timeout.
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
  SCAN_ROOTS       paths the secret scan reads (default: /home /root /opt /srv
                   /tmp /var/tmp /var/lib /etc)
  SCAN_HOMES       home directories whose credential files are listed
                   (default: /home/* /root)

Needed with --isolated:
  HOME_TARGETS     space-separated host:port pairs the box must NOT reach
  INTERNET_TARGET  one host:port the box MUST reach (proves the probe works)
  PROBE_SSH        user@host of a machine at a non-allowed address
  PROBE_CONTROL    host:port the probe MUST reach (default: INTERNET_TARGET)

Without --isolated the rows that need the isolated bridge report SKIPPED.
The root row and the secret scan need passwordless sudo on the box.
Log in once by hand first, so the box host key is already known.
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
need_tool grep
need_tool sed
if command -v timeout > /dev/null; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout > /dev/null; then
  TIMEOUT_CMD=gtimeout
else
  die "missing tool: timeout (on macOS: brew install coreutils)"
fi

DEVBOX_PORT="${DEVBOX_PORT:-22}"
SPOKE_REF="${SPOKE_REF:-main}"
COMMIT_TIMEOUT="${COMMIT_TIMEOUT:-900}"
DEVBOX_SSH_KEY="${DEVBOX_SSH_KEY:-}"
HOME_TARGETS="${HOME_TARGETS:-}"
INTERNET_TARGET="${INTERNET_TARGET:-}"
PROBE_SSH="${PROBE_SSH:-}"
PROBE_CONTROL="${PROBE_CONTROL:-$INTERNET_TARGET}"
SCAN_ROOTS="${SCAN_ROOTS:-/home /root /opt /srv /tmp /var/tmp /var/lib /etc}"
SCAN_HOMES="${SCAN_HOMES:-/home/* /root}"

for name in DEVBOX_HOST DEVBOX_USER DEVENV_IMAGE SPOKE_REPO; do need_input "$name"; done
valid DEVBOX_HOST "$DEVBOX_HOST" '^[A-Za-z0-9._:][A-Za-z0-9._:-]*$'
valid DEVBOX_USER "$DEVBOX_USER" '^[a-z_][a-z0-9_-]*$'
valid DEVBOX_PORT "$DEVBOX_PORT" '^[0-9]{1,5}$'
valid DEVENV_IMAGE "$DEVENV_IMAGE" '^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
valid SPOKE_REPO "$SPOKE_REPO" '^https://[A-Za-z0-9._/-]+$'
valid SPOKE_REF "$SPOKE_REF" '^[A-Za-z0-9._/][A-Za-z0-9._/-]*$'
valid COMMIT_TIMEOUT "$COMMIT_TIMEOUT" '^[0-9]{1,5}$'
valid SCAN_ROOTS "$SCAN_ROOTS" '^[A-Za-z0-9._/ *-]+$'
valid SCAN_HOMES "$SCAN_HOMES" '^[A-Za-z0-9._/ *-]+$'
if [[ -n "$DEVBOX_SSH_KEY" ]]; then valid DEVBOX_SSH_KEY "$DEVBOX_SSH_KEY" '^[A-Za-z0-9._/~][A-Za-z0-9._/~-]*$'; fi

if ((ISOLATED)); then
  if [[ -z "${HOME_TARGETS//[[:space:]]/}" ]]; then die "missing input: HOME_TARGETS"; fi
  need_input INTERNET_TARGET
  need_input PROBE_SSH
  valid PROBE_SSH "$PROBE_SSH" '^[A-Za-z0-9._@:][A-Za-z0-9._@:-]*$'
  for t in $HOME_TARGETS $INTERNET_TARGET $PROBE_CONTROL; do
    valid TARGET "$t" '^[A-Za-z0-9._][A-Za-z0-9._-]*:[0-9]{1,5}$'
  done
fi

# ForwardAgent=no keeps the box away from the laptop's keys. A row that needs
# a login must not prompt, so BatchMode stays on.
SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no -p "$DEVBOX_PORT")
if [[ -n "$DEVBOX_SSH_KEY" ]]; then SSH_BASE+=(-i "$DEVBOX_SSH_KEY"); fi

ROWS=()
FAILS=0
SKIPPED=0
LIMITED=0
FINDINGS=()

add_row() {
  ROWS+=("$(printf '%-36s %-8s %s' "$1" "$2" "$3")")
  case "$2" in
    FAIL) FAILS=$((FAILS + 1)) ;;
    SKIPPED) SKIPPED=$((SKIPPED + 1)) ;;
    LIMITED) LIMITED=$((LIMITED + 1)) ;;
  esac
}

# Runs a script on the box over SSH. Arguments reach the script as quoted
# positional parameters, so a value can never become a command.
remote() {
  local limit="$1" script="$2" quoted="" arg
  shift 2
  for arg in "$@"; do quoted+=" $(printf '%q' "$arg")"; done
  printf '%s\n' "$script" | "$TIMEOUT_CMD" "$limit" ssh "${SSH_BASE[@]}" "$DEVBOX_USER@$DEVBOX_HOST" "bash -s --$quoted" 2> /dev/null
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
# The refusal at the door can come from a closed port or a missing key. The
# effective sshd config shows the real setting, but it needs sudo.
ROOT_SCRIPT='# row:rootcfg
if ! sudo -n true 2> /dev/null; then
  echo SUDO_MISSING
  exit 0
fi
sshd=$(command -v sshd || echo /usr/sbin/sshd)
if ! cfg=$(sudo -n "$sshd" -T 2> /dev/null); then
  echo SSHD_ERROR
  exit 0
fi
if grep -qi "^permitrootlogin no$" <<< "$cfg"; then echo ROOT_NO; else echo ROOT_OTHER; fi'
root_out=$(ssh "${SSH_BASE[@]}" "root@$DEVBOX_HOST" true 2>&1 < /dev/null) && root_rc=0 || root_rc=$?
if ((root_rc == 0)); then
  add_row "root login refused" FAIL "root login worked"
elif [[ -z "$(denied_methods "$root_out")" ]]; then
  add_row "root login refused" FAIL "no clear refusal; the box may be unreachable"
elif ((LOGIN_OK == 0)); then
  add_row "root login refused" FAIL "needs a login"
else
  cfg_out=$(remote 30 "$ROOT_SCRIPT" || true)
  if grep -qx ROOT_NO <<< "$cfg_out"; then
    add_row "root login refused" PASS "refused and sshd config says no"
  elif grep -qx SUDO_MISSING <<< "$cfg_out"; then
    add_row "root login refused" LIMITED "no sudo -n; only the refusal was proven"
  elif grep -qx ROOT_OTHER <<< "$cfg_out"; then
    add_row "root login refused" FAIL "sshd config does not say PermitRootLogin no"
  else
    add_row "root login refused" FAIL "could not read the sshd config"
  fi
fi

# --- 4 no private key or token on the box
# The script prints paths only. Host keys under /etc/ssh are expected.
# SCAN_DONE comes last, so a scan that stops early cannot pass. grep exits 0
# or 1 when it finishes and 2 or more on an error.
SECRETS_SCRIPT='# row:secrets
set -u
roots=$1 homes=$2
use=""
scope=user
if sudo -n true 2> /dev/null; then
  use="sudo -n"
  scope=root
fi
existing=""
for r in $roots; do
  if [ -d "$r" ]; then existing="$existing $r"; fi
done
if [ -z "$existing" ]; then
  echo SCAN_ERROR
  exit 0
fi
tmp=$(mktemp)
trap "rm -f \"$tmp\"" EXIT
rc=0
# shellcheck disable=SC2086
$use grep -rIlE \
  -e "BEGIN ((RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED) )?PRIVATE KEY" \
  -e "ghp_[A-Za-z0-9]{36}" -e "github_pat_[A-Za-z0-9_]{22,}" \
  -e "glpat-[A-Za-z0-9_-]{20,}" -e "AKIA[0-9A-Z]{16}" -e "xox[baprs]-[A-Za-z0-9-]{10,}" \
  $existing > "$tmp" 2> /dev/null || rc=$?
if [ "$rc" -gt 1 ]; then
  echo SCAN_ERROR
  exit 0
fi
grep -vE "/etc/ssh/ssh_host_" "$tmp" || true
for home in $homes; do
  for f in .git-credentials .netrc .aws/credentials .kube/config .config/gh/hosts.yml .npmrc .pypirc; do
    # shellcheck disable=SC2086
    if $use test -f "$home/$f" 2> /dev/null; then echo "$home/$f"; fi
  done
  # shellcheck disable=SC2086
  if $use test -f "$home/.docker/config.json" 2> /dev/null && $use grep -q "\"auth\"" "$home/.docker/config.json" 2> /dev/null; then
    echo "$home/.docker/config.json"
  fi
done
echo "SCAN_DONE scope=$scope"'
if ((LOGIN_OK)); then
  sec_out=$(remote 120 "$SECRETS_SCRIPT" "$SCAN_ROOTS" "$SCAN_HOMES" || true)
  if ! grep -q '^SCAN_DONE ' <<< "$sec_out" || grep -qx SCAN_ERROR <<< "$sec_out"; then
    add_row "no private key or token" FAIL "the scan did not finish"
  else
    scope=$(sed -nE 's/^SCAN_DONE scope=(.*)$/\1/p' <<< "$sec_out" | head -n 1)
    found=()
    while IFS= read -r line; do found+=("$line"); done < <(grep '^/' <<< "$sec_out" || true)
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
# The container has a name, so a timeout that kills the client can still remove it.
if ((LOGIN_OK)); then
  docker_out=$(remote 400 '# row:docker
set -euo pipefail
name=acc-docker-$$
trap "docker rm -f \"$name\" > /dev/null 2>&1 || true" EXIT
docker run --rm --name "$name" "$1" true
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
# The container runs as root, so its files can block a plain rm. The fallback
# removes the whole work directory from inside a container.
if ((LOGIN_OK)); then
  commit_out=$(remote $((COMMIT_TIMEOUT + 180)) '# row:commit
set -euo pipefail
repo=$1 ref=$2 image=$3 limit=$4
work=$(mktemp -d)
name=acc-commit-$$
cleanup() {
  docker rm -f "$name" > /dev/null 2>&1 || true
  rm -rf "$work" 2> /dev/null || true
  if [ -e "$work" ]; then
    docker run --rm -v "$(dirname "$work"):/x" "$image" rm -rf "/x/$(basename "$work")" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
git clone --quiet -- "$repo" "$work/spoke"
git -C "$work/spoke" checkout --quiet "$ref" --
timeout "$limit" docker run --rm --name "$name" -v "$work/spoke:/w" -w /w \
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
# BLOCKED needs a refusal or a timeout. Any other failure, such as a name
# lookup error, is ERROR, so a typo cannot pass as isolation.
NET_SCRIPT='# row:net
out=$(timeout 5 bash -c "exec 3<>\"/dev/tcp/\$0/\$1\"" "$1" "$2" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  echo OPEN
elif [ "$rc" -eq 124 ]; then
  echo BLOCKED
elif grep -qiE "refused|unreachable|no route|timed out" <<< "$out"; then
  echo BLOCKED
else
  echo ERROR
fi'

net_result() { # target -> prints OPEN, BLOCKED, ERROR or UNKNOWN
  local out
  out=$(remote 30 "$NET_SCRIPT" "${1%%:*}" "${1##*:}" || true)
  if grep -qx OPEN <<< "$out"; then
    echo OPEN
  elif grep -qx BLOCKED <<< "$out"; then
    echo BLOCKED
  elif grep -qx ERROR <<< "$out"; then
    echo ERROR
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
        ERROR) add_row "home target $i blocked" FAIL "failed without a refusal or a timeout" ;;
        *) add_row "home target $i blocked" FAIL "no answer from the box" ;;
      esac
    done
  else
    add_row "internet reachable (control)" FAIL "needs a login"
    add_row "home targets blocked" FAIL "needs a login"
  fi

  probe_ssh=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no)
  probe_run() { # host:port -> prints OPEN, BLOCKED, ERROR or UNKNOWN
    local out
    out=$(printf '%s\n' "$NET_SCRIPT" | "$TIMEOUT_CMD" 30 "${probe_ssh[@]}" -- "$PROBE_SSH" \
      "bash -s -- $(printf '%q' "${1%%:*}") $(printf '%q' "${1##*:}")" 2> /dev/null || true)
    if grep -qx OPEN <<< "$out"; then
      echo OPEN
    elif grep -qx BLOCKED <<< "$out"; then
      echo BLOCKED
    elif grep -qx ERROR <<< "$out"; then
      echo ERROR
    else
      echo UNKNOWN
    fi
  }
  probe_login=$(printf '%s\n' '# row:probelogin
echo ACCEPTANCE_OK' | "$TIMEOUT_CMD" 30 "${probe_ssh[@]}" -- "$PROBE_SSH" "bash -s --" 2> /dev/null || true)
  if ! grep -qx ACCEPTANCE_OK <<< "$probe_login"; then
    add_row "non-allowed address refused" FAIL "the probe host did not log in"
  elif [[ "$(probe_run "$PROBE_CONTROL")" != OPEN ]]; then
    add_row "non-allowed address refused" FAIL "the probe control failed"
  else
    case "$(probe_run "$DEVBOX_HOST:$DEVBOX_PORT")" in
      BLOCKED) add_row "non-allowed address refused" PASS "" ;;
      OPEN) add_row "non-allowed address refused" FAIL "the probe reached the SSH port" ;;
      ERROR) add_row "non-allowed address refused" FAIL "failed without a refusal or a timeout" ;;
      *) add_row "non-allowed address refused" FAIL "no answer from the probe host" ;;
    esac
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
if ((SKIPPED + LIMITED > 0)); then
  echo "RESULT: PASS ($SKIPPED skipped, $LIMITED limited)"
  exit 0
fi
echo "RESULT: PASS"
