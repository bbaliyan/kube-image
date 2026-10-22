# kube-devbox

The dev box image: a disposable VM for development and validation. It is not a
jump host and not a build server.

- `ansible/` holds `devbox_common`, one role shared by every provider.
- `packer/proxmox/` builds the Proxmox template. An AWS template follows later.
- `tests/` holds fixture variables and the role tests.

The spec is in the cloud-hub repo, in the dev box spec. The box is built from
code, rebuilt instead of repaired, and holds no credentials.

## What the image contains

- Docker, with the login user in the `docker` group.
- SSH with keys only. No passwords and no root login. Agent forwarding is on, so Git access comes from your own machine's agent.
- A firewall inside the box. It allows SSH only from the sources given at launch, and from the tailnet interface.
- Tailscale, installed but not joined.
- Automatic security updates.
- The pinned `kube-devenv` image, already pulled, so the first run is fast.
- A weekly Docker prune, so the disk does not fill.

## What you give at launch

Nothing site-specific is in the image. Cloud-init writes these at launch:

| Input | Where it goes |
|---|---|
| SSH public keys | `authorized_keys` of the login user (standard cloud-init) |
| Allowed SSH sources | `/etc/devbox/launch.env`, as `DEVBOX_SSH_SOURCES="addr addr/prefix"` |
| Tailnet auth key | `/etc/devbox/tailscale-authkey`, deleted after the join |
| Tailnet tag | `/etc/devbox/launch.env`, as `DEVBOX_TAILNET_TAG=tag:name` |

If the allowed sources are missing or wrong, the firewall loads with no SSH rule.
The box is then reachable only through the tailnet. It never fails open.

## Tests

1. Run `make test-commit`. This runs the static role tests. It also validates the Packer template with fixture values.
2. On a host with Docker, run `make test-devbox-container`. This runs the role in an AlmaLinux 10 container and checks the result.

The container has no systemd. The tests do not cover starting services, pulling the
`kube-devenv` image, or the cleanup step. Only a real image build covers those.
