#!/usr/bin/env bash
# Runs build.sh with Packer/Ansible timing instrumentation on, and tees the
# full timestamped output to a log file for post-build analysis. See
# README.md's "Profiling a slow build".
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_dir="${script_dir}/build-logs"
mkdir -p "${log_dir}"
log_file="${log_dir}/$(date -u +%Y%m%dT%H%M%SZ).log"

export PACKER_BUILD_TIMESTAMPS="${PACKER_BUILD_TIMESTAMPS:-1}"
# profile_tasks/timer live in community.general, not ansible-core — kube-devenv
# deliberately ships only bare ansible-core, so install it here rather than
# growing the base image for a debugging-only dependency. Installed to a
# script-local dir and pointed at explicitly via ANSIBLE_COLLECTIONS_PATH
# instead of trusting ansible-galaxy's and ansible-playbook's default search
# paths to agree — they didn't (galaxy install "succeeded" but ansible-playbook
# still warned "unable to load", implying a mismatch neither is worth chasing
# further when pinning both ends removes the ambiguity outright).
collections_dir="${script_dir}/.ansible-collections"
mkdir -p "${collections_dir}"
ansible-galaxy collection install community.general -p "${collections_dir}" >/dev/null
export ANSIBLE_COLLECTIONS_PATH="${collections_dir}"
export ANSIBLE_CALLBACKS_ENABLED="${ANSIBLE_CALLBACKS_ENABLED:-community.general.profile_tasks,community.general.timer}"

# build.sh forwards $@ straight to 'packer init', which requires a TEMPLATE
# argument — default to the current directory, the usual `./build.sh .` call.
if [ "$#" -eq 0 ]; then
  set -- "."
fi

echo "Profiling build — full output also saved to ${log_file}" >&2

# Redirects this shell's own output through tee via process substitution,
# rather than piping build.sh's invocation into tee. The latter runs build.sh
# as the left half of a pipeline: Ctrl-C then returns control once tee (the
# pipeline's last stage) exits, without waiting for packer build — several
# process levels down inside build.sh — to finish its own graceful cleanup
# (terminate VM, delete temp resources), leaving them orphaned. This form
# keeps build.sh as this script's own direct foreground child, so Ctrl-C
# blocks until Packer's real cleanup is done, same as a plain './build.sh .'.
exec > >(tee "${log_file}") 2>&1
"${script_dir}/build.sh" "$@"
