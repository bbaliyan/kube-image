# Proxmox Packer template

Bakes an RKE2 node image as a Proxmox VM template, cloned from a one-time seed
AlmaLinux 10 template.

## One-time setup: create the seed template

kube-image clones from an existing AlmaLinux 10 Proxmox template rather than
installing from ISO. Create it once per Proxmox cluster with the automated
`seed/` OpenTofu config (a sibling of this directory, `packer/proxmox/seed/`)
— no manual Proxmox UI or `qm` commands. This is a one-time step per Proxmox
cluster, not per build — every subsequent `packer build` clones from the
same seed.

Proxmox API credentials come from `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`
(already loaded by the devcontainer). Uploading the vendor-data snippet that
installs `qemu-guest-agent` on the seed needs a separate SSH connection to the
Proxmox host itself — two ways to authenticate:

**With an SSH key** (default: the dedicated `tofu` PAM user +
`~/.ssh/id_ed25519_tofu` — the same PVE-ops account this project's
`kube-examples` consumer repo already provisions; see its
`live/proxmox/README.md`, "One-time: user and token setup"):

```bash
# From this directory (packer/proxmox/):
cd seed
tofu init
tofu apply \
  -var proxmox_node=t630 \
  -var disk_datastore_id=nvme-pool \
  -var iso_datastore_id=local \
  -var proxmox_ssh_address=pve.local
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
  -var proxmox_ssh_address=pve.local \
  -var proxmox_ssh_user=root \
  -var proxmox_ssh_password="$(read -srp 'PVE SSH password: ' p && echo "$p")"
```

(the subshell keeps the password out of shell history and `ps`;
`TF_VAR_proxmox_ssh_password` as an env var works too — never put it in a
committed `.tfvars` file.)

A few things to know before running either command:

- `iso_datastore_id` must support both the `import` and `snippets` content
  types. PVE directory-backed storage typically supports both, but
  `snippets` may need enabling separately — check under
  Datacenter → Storage → your datastore → Content.
- `os_image_url` defaults to the current AlmaLinux 10 GenericCloud image —
  override it only if you need a different mirror or build.
- Note the `seed_template_vm_id` output — that's the `seed_template_vm_id`
  value `proxmox.auto.pkrvars.hcl` needs, below.

## Building

Run `packer` from inside this directory (`packer/proxmox/`) — the Ansible
provisioner's playbook path in `template.pkr.hcl` is relative to the current
working directory, not the repo root.

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# edit proxmox.auto.pkrvars.hcl: proxmox_node, seed_template_vm_id,
# disk_datastore_id
packer init .
./build.sh .
```

`proxmox_url`/`proxmox_api_token_id`/`proxmox_api_token_secret` don't need
editing — `build.sh` derives them fresh from `PROXMOX_VE_ENDPOINT`/
`PROXMOX_VE_API_TOKEN` immediately before every build (a thin wrapper around
`packer build`; see the comment at the top of `build.sh` for why a plain
`packer build` isn't used directly — the devcontainer's own automatic
derivation only re-runs on a new shell, so refreshing the token with
`kube-proxmox-login` and reusing the same terminal can otherwise build with a
stale, already-expired token).

`k8s_version`/`cilium_version`/`argocd_version` don't need editing either —
`build.sh` fetches kube-platform's `platform/platform-versions/values.yaml`
before every build and resolves all three from it, so the baked image can't
silently drift from what Argo CD will actually run once it adopts Cilium and
itself from the genesis install. This needs network access to
`raw.githubusercontent.com` and to the Cilium/Argo CD Helm repos (the render
below also needs the latter). Do **not** set these three in
`proxmox.auto.pkrvars.hcl` — a var-file entry outranks `build.sh`'s exported
`PKR_VAR_*`, silently defeating the fetch; `export PKR_VAR_cilium_version=...`
(etc.) at the shell first if you need a specific pin instead of the current
`platform-versions.yaml` value.

`build.sh` also renders the genesis Cilium/Argo CD manifests (`helm template`
against `helm-values/cilium-values.yaml`/`argocd-values.yaml`, at the
resolved versions) into a temp directory on this machine, then the Ansible
provisioner copies the result onto the template at
`/opt/kube-compute/manifests/{cilium.yaml,00-argocd.yaml}` — rendering here
rather than on the VM being baked, and baking the result rather than
re-rendering on every cluster's `tofu apply`, is what keeps Argo CD's ~1.9 MB
of CRDs out of `node-bootstrap`'s cloud-init payload (which has a hard 1 MiB
cap on Proxmox).

Building outside the devcontainer, or without `build.sh`? Set all six
(`proxmox_url`/`proxmox_api_token_id`/`proxmox_api_token_secret`/
`k8s_version`/`cilium_version`/`argocd_version`) explicitly in
`proxmox.auto.pkrvars.hcl` instead (commented-out examples are in
`proxmox.auto.pkrvars.hcl.example`), render the two manifests yourself with
the same `helm template` invocations `build.sh` runs, and pass
`-var rendered_manifests_dir=<path to the directory containing them>` on the
`packer build .` command line — there's no default, so a bare `packer build`
with none of this set fails immediately rather than baking a stale or empty
manifest.

## Second build target: proxmox-autoscaler-worker

This directory holds two Packer build blocks (Packer loads every `*.pkr.hcl`
file in a directory as one merged config):

- `rke2-proxmox` (`template.pkr.hcl`) — the default, documented above: a full
  RKE2 install baked onto the template, plus the genesis Cilium/Argo CD
  manifests.
- `proxmox-autoscaler-worker` (`autoscaler-worker.pkr.hcl`) — a second,
  lighter image variant for CAPI-managed (cluster-autoscaler) worker nodes.
  It does **not** install RKE2. Instead it stages:
  - `/opt/kube-compute/manifests/capi-install.yaml` — the concatenated
    `clusterctl generate provider` output for CAPI core + CAPMOX + CAPRKE2
    (bootstrap + control-plane).
  - `/opt/install.sh` + `/opt/rke2-artifacts/{rke2.linux-amd64.tar.gz,
    rke2-images.linux-amd64.tar.zst,sha256sum-amd64.txt}` — RKE2's own
    air-gap artifact layout, for CAPRKE2's own boot-time `install.sh`
    re-invocation to consume once a `Machine` boots from this template
    (entirely outside this repo's control from that point on).

  `build.sh` only resolves `capi_core_version`/`capmox_version`/
  `caprke2_version` (from kube-platform's `platform-versions.yaml` —
  `capiCoreVersion`/`capmoxVersion`/`caprke2Version`) and only calls
  `clusterctl generate provider` when this target is actually being built —
  building `rke2-proxmox` alone never needs a `clusterctl` binary or those
  version keys to exist.

`build.sh` has no HCL-level "build target" variable to select between the
two — Packer's own CLI provides that via `-only=<build_name>.<source_type>.<source_name>`.
Without an explicit `-only`, `build.sh` defaults to building only
`rke2-proxmox` (preserving this script's pre-existing behavior from before
this second target existed) — a bare `packer build .` (bypassing `build.sh`)
would otherwise build **both** targets on every invocation, since that's
Packer's own default when a directory has more than one build block.

```bash
# Build only the new autoscaler-worker target:
./build.sh -only=proxmox-autoscaler-worker.proxmox-clone.autoscaler-worker .

# Build only the pre-existing control-plane/pool target (same as omitting
# -only entirely — this is build.sh's default):
./build.sh -only=rke2-proxmox.proxmox-clone.rke2 .
```

Needs a `clusterctl` binary on the build host and network access to
`raw.githubusercontent.com`/the provider repos it fetches
`clusterctl generate provider` manifests from, in addition to everything
`rke2-proxmox` already needs. Requires kube-platform's
`platform/platform-versions/values.yaml` to carry `capiCoreVersion`/
`capmoxVersion`/`caprke2Version` — not present until that repo's own
version-pin change lands.

## Pruning old builds

Every `packer build` leaves the previous one's template around — Packer has
no build history or artifact retention of its own (no `packer destroy`).
`prune-images.sh` finds every VM tagged `kube-image;template` on a node,
keeps the N most recent (by the build date embedded in the name), and
destroys the rest. It never touches the seed (tagged `seed-template`, not
`template`) or anything not built by this repo.

```bash
./prune-images.sh --node t630 --dry-run   # see what would be destroyed
./prune-images.sh --node t630             # keeps 3 by default, asks to confirm
./prune-images.sh --node t630 --keep 5 --yes   # non-interactive
```

Talks to the Proxmox API directly (no SSH needed, unlike the seed step
above) — same `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN` the rest of this
repo uses.

## Validating without a live Proxmox connection

```bash
packer fmt -check .
packer validate .
```
