# devbox_common

The one role shared by every dev box image, on every provider.

It is a skeleton for now. It only verifies that the base image is AlmaLinux 10.
Later tickets add Docker, SSH hardening and the pre-pulled kube-devenv image.

Rules for this role:

- Nothing site-specific is baked. The tailnet tag, the allowed addresses and the keys are launch-time inputs.
- The role holds no credential, no private key and no token.
