# devbox_common

The one role shared by every dev box image, on every provider.

It installs Docker, hardens SSH, sets up the firewall and automatic security updates,
installs Tailscale without joining, and pulls the pinned `kube-devenv` image. It ends
by removing SSH host keys, the machine ID and the cloud-init state.

The `devbox_manage_services`, `devbox_pull_devenv_image` and `devbox_clean_for_template`
variables switch off the parts that need systemd or a Docker daemon. Only the container
test turns them off.

Rules for this role:

- Nothing site-specific is baked. The tailnet tag, the allowed addresses and the keys are launch-time inputs.
- The role holds no credential, no private key and no token.
