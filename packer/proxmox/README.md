# Proxmox Packer template

Bakes an RKE2 node image as a Proxmox VM template, cloned from a one-time seed
AlmaLinux 10 template.

## One-time setup: create the seed template

kube-image clones from an existing AlmaLinux 10 Proxmox template rather than
installing from ISO. Create it once per Proxmox cluster with the automated
`seed/` OpenTofu config (`packer/proxmox/seed/`) — no manual Proxmox UI or
`qm` commands. Every subsequent `packer build` clones from the same seed.

Proxmox API credentials come from `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`
(see the root README's "Proxmox credentials"). Uploading the vendor-data
snippet that installs `qemu-guest-agent` on the seed needs a separate SSH
connection to the Proxmox host itself:

**With an SSH key** (default: the dedicated `tofu` PAM user +
`~/.ssh/id_ed25519_tofu` — the same PVE-ops account this project's
`kube-examples` consumer repo already provisions; see its
`live/proxmox/README.md`, "One-time: user and token setup"):

```bash
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.lan
```

**No SSH key set up?** Pass a password instead — override `proxmox_ssh_user`
to whatever account you have a password for:

```bash
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.lan \
  -var proxmox_ssh_user=root \
  -var proxmox_ssh_password="$(read -srp 'PVE SSH password: ' p && echo "$p")"
```

(the subshell keeps the password out of shell history and `ps`;
`TF_VAR_proxmox_ssh_password` as an env var works too — never put it in a
committed `.tfvars` file.)

A few things to know before running either command:

- `iso_datastore_id` must support both the `import` and `snippets` content
  types. PVE directory-backed storage typically supports both, but
  `snippets` may need enabling separately (Datacenter → Storage → your
  datastore → Content).
- `os_image_url` defaults to the current AlmaLinux 10 GenericCloud image —
  override only for a different mirror or build.
- Note the `seed_template_vm_id` output — that's what
  `proxmox.auto.pkrvars.hcl` needs, below.

## Building

Run `packer` from inside this directory — the Ansible provisioner's
playbook path in `template.pkr.hcl` is relative to the current working
directory, not the repo root.

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl: proxmox_node, seed_template_vm_id,
# disk_datastore_id
packer init .
./build.sh .
```

`build.sh` is a thin wrapper around `packer build`, not optional boilerplate
— it does three things a plain `packer build` can't:

1. Re-derives `proxmox_url`/`proxmox_api_token_id`/`proxmox_api_token_secret`
   from the current `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` right before
   building, so a token refreshed with `kube-proxmox-login` in the same
   terminal is always picked up (the devcontainer's own export only runs
   once, at shell start).
2. Resolves `k8s_version`/`cilium_version`/`argocd_version` (and
   `capi_core_version`/`capmox_version`) from kube-platform's
   `platform/platform-versions/values.yaml`, so the image can't silently
   drift from what Argo CD will run. **Do not** set these in
   `proxmox.auto.pkrvars.hcl` — a var-file entry outranks `build.sh`'s
   exported `PKR_VAR_*` and would silently defeat the fetch; export
   `PKR_VAR_cilium_version=...` (etc.) at the shell first for a specific pin.
3. Renders the genesis Cilium/Argo CD manifests (`helm template`) and the
   CAPI/CAPMOX install manifest (`clusterctl generate provider`) into a temp
   dir, for the Ansible provisioner to copy onto the template. Rendered here
   rather than at `kube-compute` apply time because Argo CD's chart alone is
   ~1.9 MB with CRDs — well past Proxmox's 1 MiB cicustom snippet cap.

Building outside the devcontainer or without `build.sh`? Set all six
resolved variables explicitly in `proxmox.auto.pkrvars.hcl` (see
`proxmox.auto.pkrvars.hcl.example`), render the manifests yourself the same
way `build.sh` does, and pass `-var rendered_manifests_dir=...` and
`-var rendered_capi_manifests_dir=...` on the command line — there's no
default, so a bare `packer build` fails immediately instead of baking a
stale or empty manifest.

## CAPI/CAPMOX install manifest

This template unconditionally stages
`/opt/kube-compute/manifests/capi-install.yaml` — CAPI core + CAPMOX only
(no bootstrap/control-plane provider) — the same way it bakes the
Cilium/Argo CD manifests regardless of whether a given cluster later enables
cluster-autoscaler. `kube-compute`'s `bootstrap.sh.tftpl` applies it from
the genesis node on clusters with `cluster_autoscaler_enabled = true`.
Cluster-autoscaler workers join via a plain
`Machine.spec.bootstrap.dataSecretName`, bypassing any bootstrap-provider
CRD, so every autoscaler-worker `Machine` boots from this same template —
there's no second, lighter image variant.

CAPMOX's `--infrastructure` generation templates a manager-wide credentials
Secret (`capmox-manager-credentials`) from `PROXMOX_URL`/`PROXMOX_TOKEN`/
`PROXMOX_SECRET`. **`build.sh` sets these to fixed, non-functional
placeholder values — never the real Proxmox endpoint/token.** Whatever
lands there is baked in plaintext into every image and applied on every
cluster's genesis node, so a real credential there would be a standing leak
readable from disk on every VM ever cloned from the template. It doesn't
need to be real: every `ProxmoxCluster` this project renders sets its own
`spec.credentialsRef`, which CAPMOX's controller prefers over the
manager-wide Secret — real per-cluster credentials are delivered by the
consumer repo at runtime instead (e.g. External Secrets Operator). A
cluster with a missing/wrong `credentialsRef` fails loudly rather than
silently reconciling against a leaked fallback.

Requires kube-platform's `platform-versions.yaml` to carry
`capiCoreVersion`/`capmoxVersion`.

## VM template naming

Self-descriptive:
`almalinux10-kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>`.
Point `kube-compute`'s `proxmox-control-plane`/`proxmox-node-pool` modules
at the resulting template's numeric Proxmox VM ID via
`proxmox_template_vm_id`. The name is documentation only — kube-compute
performs no compatibility check against it.

Each template is also tagged `kube-image`, `template`, the sanitized
`k8s_version`, `almalinux10`, and `seed-vm-<seed_template_vm_id>` (the seed
this build cloned from — Proxmox has no queryable "resolved source" the way
AWS's `source-ami-id` tag traces one, so the seed VM ID is the closest
equivalent fact worth recording).

## Pruning old builds

Every `packer build` leaves the previous template around — Packer has no
build history or artifact retention of its own. `prune-images.sh` finds
every VM tagged `kube-image;template` on a node, keeps the N most recent (by
the build date embedded in the name), and destroys the rest. It never
touches the seed (tagged `seed-template`, not `template`).

```bash
./prune-images.sh --node t630 --dry-run   # see what would be destroyed
./prune-images.sh --node t630             # keeps 3 by default, asks to confirm
./prune-images.sh --node t630 --keep 5 --yes   # non-interactive
```

Talks to the Proxmox API directly (no SSH needed), using the same
`PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` as the rest of this repo.

## Validating without a live Proxmox connection

```bash
packer fmt -check .
packer validate .
```
