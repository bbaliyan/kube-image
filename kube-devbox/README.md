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
- A firewall inside the box. It allows SSH only from the sources given at launch, and from the tailnet interface when launch input is valid.
- Tailscale, installed but not joined.
- Automatic security updates.
- The pinned `kube-devenv` image, already pulled, so the first run is fast.
- A weekly Docker prune, so the disk does not fill.

## Launch contract

Nothing site-specific is in the image. Cloud-init must write these files at launch.

| Path | Owner | Mode | Format |
|---|---|---|---|
| `/etc/devbox/launch.env` | root | 0644 | Shell variables, one per line (see below) |
| `/etc/devbox/tailscale-authkey` | root | 0600 | The auth key only, on one line |

`launch.env` is read as a shell file. Quote every value that holds a space.
An unquoted list breaks the file, and the firewall then loads with no SSH rule.

| Variable | Meaning | Default |
|---|---|---|
| `DEVBOX_SSH_SOURCES` | Addresses or CIDR ranges allowed to open SSH. Space-separated, in double quotes. | none: no SSH |
| `DEVBOX_TAILNET_INTERFACE` | Interface name that also accepts SSH. | `tailscale0` |
| `DEVBOX_TAILNET_TAG` | Tag the box advertises when it joins the tailnet. | `tag:dev` |

SSH public keys use the standard cloud-init `ssh_authorized_keys` key. The template keeps the
public key that built it in its cloud-init drive. A clone accepts that key unless the launch
overrides the SSH keys.

Example cloud-init user data:

```yaml
#cloud-config
write_files:
  - path: /etc/devbox/launch.env
    owner: root:root
    permissions: "0644"
    content: |
      DEVBOX_SSH_SOURCES="192.0.2.10 198.51.100.0/24"
      DEVBOX_TAILNET_TAG=tag:dev
  - path: /etc/devbox/tailscale-authkey
    owner: root:root
    permissions: "0600"
    content: "REPLACE-WITH-THE-AUTH-KEY"
```

Warning: do not set `defer: true` on these files. Both files must exist before
`cloud-init.service` finishes. If they do not, the firewall loads with no SSH rule.

If the allowed sources are missing, empty or malformed, the firewall loads fully closed.
That means no SSH from anywhere, and the tailnet rule is also dropped. Relaunch the box with
a correct `launch.env`. If the `tailscale up` join fails, the auth key is deleted anyway. Relaunch the box with a new key.

## Docker ports and the firewall

The box firewall has an input chain only. A port that you publish with `docker run -p`
bypasses it, because Docker forwards that traffic. On the LAN, the OPNsense firewall is the
only layer for published ports until Slice 10. Do not publish ports on a shared network.

## Tests

1. Run `make test-commit`. This runs the static role tests. It also validates the Packer template with fixture values.
2. On a host with Docker, run `make test-devbox-container`. This runs the role in an AlmaLinux 10 container and checks the result.

The container has no systemd. The tests do not cover starting services, pulling the
`kube-devenv` image, or the cleanup step. Only a real image build covers those.
