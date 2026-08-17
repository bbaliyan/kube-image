#!/usr/bin/env bash
# Deletes orphaned temporary IAM roles/instance profiles left behind by a
# failed Packer cleanup. packer-plugin-amazon deletes its temp role's inline
# policy and the role itself back-to-back with no wait for IAM's eventual
# consistency, so the delete intermittently fails with "Cannot delete
# entity, must detach all policies first" — harmless to the built AMI, but
# it leaks the role. Upstream behavior, not fixable here.
#
# Every real build self-provisions one of these (template.pkr.hcl's
# temporary_iam_instance_profile_policy_document, for Session Manager
# access), so run this periodically to sweep up what the race above leaves
# behind. Matches by RoleName prefix "packer-" and the exact description
# the plugin sets, so it never touches an unrelated role. IAM has no
# regions, so unlike prune-images.sh this isn't region-scoped.
#
# Usage: ./prune-orphaned-iam.sh [--older-than-minutes N] [--dry-run] [--yes]
#   --older-than-minutes  Only touch roles created at least this long ago, so
#                         a build running concurrently is never a target (default: 60)
#   --dry-run             List what would be deleted, change nothing
#   --yes                 Skip the confirmation prompt
set -euo pipefail

OLDER_THAN_MINUTES=60
DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --older-than-minutes)
      OLDER_THAN_MINUTES="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--older-than-minutes N] [--dry-run] [--yes]" >&2
      exit 1
      ;;
  esac
done

cutoff_epoch="$(date -u -d "${OLDER_THAN_MINUTES} minutes ago" +%s)"

mapfile -t ROLES < <(
  aws iam list-roles \
    --query "Roles[?starts_with(RoleName, 'packer-') && Description=='Temporary role for Packer'].[RoleName,CreateDate]" \
    --output text
)

DELETE_LIST=()
for entry in "${ROLES[@]}"; do
  [ -z "$entry" ] && continue
  role_name="$(printf '%s' "$entry" | cut -f1)"
  create_date="$(printf '%s' "$entry" | cut -f2)"
  create_epoch="$(date -u -d "$create_date" +%s)"
  if [ "$create_epoch" -le "$cutoff_epoch" ]; then
    DELETE_LIST+=("$role_name")
  fi
done

if [ "${#DELETE_LIST[@]}" -eq 0 ]; then
  echo "No orphaned Packer IAM roles older than ${OLDER_THAN_MINUTES} minutes found."
  exit 0
fi

echo "Found ${#DELETE_LIST[@]} orphaned Packer IAM role(s) older than ${OLDER_THAN_MINUTES} minutes:"
printf '  %s\n' "${DELETE_LIST[@]}"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "--dry-run: no changes made."
  exit 0
fi

if [ "$ASSUME_YES" != true ]; then
  echo
  read -rp "Delete the ${#DELETE_LIST[@]} role(s) (and any instance profile of the same name) listed above? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    echo "Aborted."
    exit 1
  }
fi

# delete-role right after delete-role-policy hits the same IAM
# eventual-consistency race packer-plugin-amazon does (see header) — a few
# retries with a short sleep clears it within seconds. Not wrapped in `set
# -e`-triggering failure: one role stuck past the retry budget shouldn't
# abort the rest of the list, so failures are collected and reported at the
# end instead.
delete_role_with_retry() {
  local role_name="$1" attempt
  for attempt in 1 2 3 4 5; do
    if aws iam delete-role --role-name "$role_name" 2>/dev/null; then
      return 0
    fi
    [ "$attempt" -eq 5 ] && return 1
    sleep 5
  done
}

FAILED_LIST=()
for role_name in "${DELETE_LIST[@]}"; do
  echo "Cleaning up ${role_name}..."

  mapfile -t inline_policies < <(
    aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames' --output text
  )
  for policy_name in "${inline_policies[@]}"; do
    [ -z "$policy_name" ] && continue
    echo "  Removing inline policy ${policy_name}..."
    aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name"
  done

  # The plugin names the instance profile identically to the role.
  if aws iam get-instance-profile --instance-profile-name "$role_name" >/dev/null 2>&1; then
    echo "  Detaching role from instance profile ${role_name}..."
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "$role_name" --role-name "$role_name" 2>/dev/null || true
    echo "  Deleting instance profile ${role_name}..."
    aws iam delete-instance-profile --instance-profile-name "$role_name"
  fi

  echo "  Deleting role ${role_name}..."
  if ! delete_role_with_retry "$role_name"; then
    echo "  Failed to delete role ${role_name} after retries — leaving it for the next run." >&2
    FAILED_LIST+=("$role_name")
  fi
done

if [ "${#FAILED_LIST[@]}" -gt 0 ]; then
  echo
  echo "Done, but ${#FAILED_LIST[@]} role(s) could not be deleted (will be picked up by a later run):"
  printf '  %s\n' "${FAILED_LIST[@]}"
  exit 1
fi

echo "Done."
