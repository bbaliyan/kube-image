#!/usr/bin/env bash
# Deregisters old kube-image-built AMIs (and deletes their backing
# snapshots), keeping the N most recent. AWS counterpart of
# packer/proxmox/prune-images.sh — same "no packer-native retention, so
# talk to the provider's API directly" reasoning, using the AWS CLI instead
# of curl-against-the-Proxmox-API since kube-image already assumes an AWS
# credential chain is available for the build itself. Selects AMIs by the
# kube-image=true tag template.pkr.hcl sets; sorts by CreationDate (returned
# directly by the API, unlike Proxmox's name-embedded date) so it's correct
# regardless of any AMI-name edge case.
#
# --architecture is required and filters to one architecture at a time
# (x86_64 or arm64) — template.pkr.hcl can build both from the same repo,
# and "keep N most recent" has to apply separately per architecture, or
# pruning one arch's builds could delete the only AMI of the other arch
# just because it looked "older" in a combined list. AMIs built before this
# flag existed have no architecture tag and won't match either value —
# prune those manually once (aws ec2 deregister-image/delete-snapshot).
#
# Usage: ./prune-images.sh --region <aws-region> --architecture <x86_64|arm64> [--keep N] [--dry-run] [--yes]
#   --region        AWS region the AMIs live in (required; matches aws_region
#                   in aws.auto.pkrvars.hcl)
#   --architecture  Only prune AMIs tagged with this architecture (required;
#                   matches ami_architecture in aws.auto.pkrvars.hcl)
#   --keep          How many most-recent AMIs to keep (default: 3)
#   --dry-run       List what would be destroyed, change nothing
#   --yes           Skip the confirmation prompt
set -euo pipefail

KEEP=3
DRY_RUN=false
ASSUME_YES=false
REGION=""
ARCHITECTURE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="$2"
      shift 2
      ;;
    --architecture)
      ARCHITECTURE="$2"
      shift 2
      ;;
    --keep)
      KEEP="$2"
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
      echo "Usage: $0 --region <aws-region> --architecture <x86_64|arm64> [--keep N] [--dry-run] [--yes]" >&2
      exit 1
      ;;
  esac
done

if [ -z "$REGION" ]; then
  echo "Error: --region is required (the AWS region these AMIs live in)." >&2
  exit 1
fi

if [ -z "$ARCHITECTURE" ]; then
  echo "Error: --architecture is required (x86_64 or arm64 — prune one architecture at a time)." >&2
  exit 1
fi

# --owners self: only ever touch AMIs this account itself registered — never
# the AlmaLinux Foundation's own published AMIs (owner 764336703387) this
# build sources from.
mapfile -t AMIS < <(
  aws ec2 describe-images \
    --region "$REGION" \
    --owners self \
    --filters "Name=tag:kube-image,Values=true" "Name=tag:architecture,Values=${ARCHITECTURE}" \
    --query 'Images[].[ImageId,Name,CreationDate]' \
    --output text |
    sort -k3 -r
)

if [ "${#AMIS[@]}" -eq 0 ]; then
  echo "No kube-image AMIs found in region ${REGION} for architecture ${ARCHITECTURE}."
  exit 0
fi

echo "Found ${#AMIS[@]} kube-image AMI(s) in region ${REGION} for architecture ${ARCHITECTURE}:"
printf '  %s\n' "${AMIS[@]}"
echo

KEEP_LIST=("${AMIS[@]:0:$KEEP}")
DELETE_LIST=("${AMIS[@]:$KEEP}")

if [ "${#DELETE_LIST[@]}" -eq 0 ]; then
  echo "Nothing to prune — ${#AMIS[@]} AMI(s) found, keeping up to ${KEEP}."
  exit 0
fi

echo "Keeping the ${KEEP} most recent:"
printf '  %s\n' "${KEEP_LIST[@]}"
echo
echo "Would deregister (and delete the backing snapshot of):"
printf '  %s\n' "${DELETE_LIST[@]}"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "--dry-run: no changes made."
  exit 0
fi

if [ "$ASSUME_YES" != true ]; then
  echo
  read -rp "Deregister the ${#DELETE_LIST[@]} AMI(s) listed above? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    echo "Aborted."
    exit 1
  }
fi

for entry in "${DELETE_LIST[@]}"; do
  image_id="$(printf '%s' "$entry" | cut -f1)"
  name="$(printf '%s' "$entry" | cut -f2)"

  # Snapshot IDs must be captured before deregistering — describe-images no
  # longer returns them for an AMI once it's deregistered.
  mapfile -t snapshot_ids < <(
    aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$image_id" \
      --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' \
      --output text | tr '\t' '\n'
  )

  echo "Deregistering AMI ${image_id} (${name})..."
  aws ec2 deregister-image --region "$REGION" --image-id "$image_id"

  for snap in "${snapshot_ids[@]}"; do
    [ -z "$snap" ] && continue
    echo "Deleting snapshot ${snap}..."
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap"
  done
done

echo "Done."
