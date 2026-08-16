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

## CAPI/CAPMOX install manifest

There is only one build target in this directory (`rke2-proxmox`,
`template.pkr.hcl`) — a full RKE2 install baked onto the template, plus the
genesis Cilium/Argo CD manifests. It also unconditionally stages
`/opt/kube-compute/manifests/capi-install.yaml` — the concatenated
`clusterctl generate provider` output for CAPI core + CAPMOX only (two
`clusterctl` calls, `--core` and `--infrastructure`) — the same way the
Cilium/Argo CD manifests are baked regardless of whether a given cluster
later enables cluster-autoscaler. `kube-compute`'s `bootstrap.sh.tftpl`
applies this manifest with `kubectl apply` from the control-plane/genesis
node on clusters with `cluster_autoscaler_enabled = true`.

There is no CAPRKE2 (bootstrap/control-plane provider) install anywhere in
this manifest and no second, lighter image variant for CAPI-managed worker
nodes — cluster-autoscaler workers join via a plain
`Machine.spec.bootstrap.dataSecretName` pointing at pre-rendered cloud-init
in a Kubernetes `Secret`, entirely bypassing any bootstrap-provider CRD, so
every autoscaler-worker `Machine` boots from this same, one template.

`build.sh` resolves `capi_core_version`/`capmox_version` (from
kube-platform's `platform-versions.yaml` — `capiCoreVersion`/
`capmoxVersion`) for every build, and always renders `capi-install.yaml` via
`clusterctl generate provider`. Building requires a `clusterctl` binary on
the build host and network access to `raw.githubusercontent.com`/the
provider repos it fetches manifests from. CAPMOX's `--infrastructure`
generation templates a manager-wide credentials `Secret`
(`capmox-manager-credentials`, `capmox-system` namespace) from
`PROXMOX_URL`/`PROXMOX_TOKEN`/`PROXMOX_SECRET` (CAPMOX's own naming, distinct
from bpg/proxmox's `PROXMOX_VE_*` and this script's own `PKR_VAR_*`).

**`build.sh` deliberately sets these three to fixed, non-functional
placeholder values — never the real Proxmox endpoint/token.** Whatever lands
in this Secret is baked, in plaintext, into `capi-install.yaml`, which is
copied onto every VM image and applied on every cluster's genesis node — a
real credential there would be a standing leak, readable from disk on every
VM ever cloned from the template, whether or not CAPMOX ever consults it. It
doesn't need to be real: every `ProxmoxCluster` this project renders
(`kube-compute`'s `cluster-autoscaler-workers.yaml.tftpl`) sets its own
`spec.credentialsRef`, which CAPMOX's controller prefers over the
manager-wide Secret — real, per-cluster credentials are delivered instead by
the consumer repo at runtime (e.g. via External Secrets Operator pulling from
a vault), never baked into the image. A cluster whose `credentialsRef` Secret
is missing or wrong fails loudly (CAPMOX rejects the placeholder host, or a
real 401), rather than silently reconciling against a leaked fallback
credential. Requires kube-platform's `platform/platform-versions/values.yaml`
to carry `capiCoreVersion`/`capmoxVersion` — not present until that repo's
own version-pin change lands.

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
