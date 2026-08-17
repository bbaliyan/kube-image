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
# growing the base image for a debugging-only dependency.
ansible-galaxy collection install community.general >/dev/null
export ANSIBLE_CALLBACKS_ENABLED="${ANSIBLE_CALLBACKS_ENABLED:-community.general.profile_tasks,community.general.timer}"

# build.sh forwards $@ straight to 'packer init', which requires a TEMPLATE
# argument — default to the current directory, the usual `./build.sh .` call.
if [ "$#" -eq 0 ]; then
  set -- "."
fi

echo "Profiling build — full output also saved to ${log_file}" >&2

"${script_dir}/build.sh" "$@" 2>&1 | tee "${log_file}"
