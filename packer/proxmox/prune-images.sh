#!/usr/bin/env bash
# Destroys old kube-image-built Proxmox templates, keeping the N most recent.
#
# Packer has no artifact retention of its own (no 'packer destroy', no build
# history — every 'packer build' just creates one template and exits), so
# this talks to the Proxmox API directly instead, the same way people prune
# old AMIs/GCP images alongside Packer elsewhere. Selects VMs by the tags
# template.pkr.hcl sets ("kube-image" + "template") and explicitly excludes
# "seed-template" so the seed itself is never touched. Sorts by name — safe
# because the name embeds the build date last (kube-image-<k8s_version>-
# <cilium_version>-<argocd_version>-<build-date>) in YYYY-MM-DD order, so a
# lexicographic sort is also date order, as long as k8s_version/cilium_version/
# argocd_version stay the same width across the builds being compared (true
# within one retention run in practice — different versions still sort
# sensibly by date since YYYY-MM-DD dominates the tail of the string).
#
# Usage: ./prune-images.sh --node <proxmox-node> [--keep N] [--dry-run] [--yes]
#   --node      Proxmox node the templates live on (required; matches
#               proxmox_node in proxmox.auto.pkrvars.hcl)
#   --keep      How many most-recent templates to keep (default: 3)
#   --dry-run   List what would be destroyed, change nothing
#   --yes       Skip the confirmation prompt
set -euo pipefail

KEEP=3
DRY_RUN=false
ASSUME_YES=false
NODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      NODE="$2"
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
      echo "Usage: $0 --node <proxmox-node> [--keep N] [--dry-run] [--yes]" >&2
      exit 1
      ;;
  esac
done

if [ -z "$NODE" ]; then
  echo "Error: --node is required (the Proxmox node these templates live on)." >&2
  exit 1
fi

: "${PROXMOX_VE_ENDPOINT:?PROXMOX_VE_ENDPOINT not set — source ~/.kube-compute/proxmox-endpoint or run kube-proxmox-login}"
: "${PROXMOX_VE_API_TOKEN:?PROXMOX_VE_API_TOKEN not set — source ~/.kube-compute/proxmox or run kube-proxmox-login}"

AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}"

# -k: self-signed PVE certs are this project's assumed default everywhere else
# (seed/variables.tf's proxmox_insecure, variables.pkr.hcl's
# proxmox_insecure_skip_tls_verify both default true) — drop it if your PVE
# uses a cert you trust.
mapfile -t VMS < <(
  curl -fsSk -H "$AUTH_HEADER" "${PROXMOX_VE_ENDPOINT}/api2/json/nodes/${NODE}/qemu" |
    python3 -c "
import json, sys
data = json.load(sys.stdin)['data']
for vm in data:
    tags = vm.get('tags', '')
    tag_list = tags.split(';') if tags else []
    if 'kube-image' in tag_list and 'template' in tag_list and 'seed-template' not in tag_list:
        print(f\"{vm['vmid']}\t{vm['name']}\")
"
)

if [ "${#VMS[@]}" -eq 0 ]; then
  echo "No kube-image templates found on node ${NODE}."
  exit 0
fi

mapfile -t SORTED < <(printf '%s\n' "${VMS[@]}" | sort -t$'\t' -k2 -r)

echo "Found ${#SORTED[@]} kube-image template(s) on node ${NODE}:"
printf '  %s\n' "${SORTED[@]}"
echo

KEEP_LIST=("${SORTED[@]:0:$KEEP}")
DELETE_LIST=("${SORTED[@]:$KEEP}")

if [ "${#DELETE_LIST[@]}" -eq 0 ]; then
  echo "Nothing to prune — ${#SORTED[@]} template(s) found, keeping up to ${KEEP}."
  exit 0
fi

echo "Keeping the ${KEEP} most recent:"
printf '  %s\n' "${KEEP_LIST[@]}"
echo
echo "Would destroy:"
printf '  %s\n' "${DELETE_LIST[@]}"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "--dry-run: no changes made."
  exit 0
fi

if [ "$ASSUME_YES" != true ]; then
  echo
  read -rp "Destroy the ${#DELETE_LIST[@]} template(s) listed above? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    echo "Aborted."
    exit 1
  }
fi

for entry in "${DELETE_LIST[@]}"; do
  vmid="${entry%%$'\t'*}"
  name="${entry#*$'\t'}"
  echo "Destroying VM ${vmid} (${name})..."
  curl -fsSk -X DELETE -H "$AUTH_HEADER" "${PROXMOX_VE_ENDPOINT}/api2/json/nodes/${NODE}/qemu/${vmid}"
  echo
done

echo "Done."
