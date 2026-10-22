# kube-devbox

The dev box image: a disposable VM for development and validation. It is not a
jump host and not a build server.

- `ansible/` holds `devbox_common`, one role shared by every provider.
- `packer/proxmox/` builds the Proxmox template. An AWS template follows later.
- `scripts/acceptance.sh` verifies a built box. See the next section.
- `tests/` holds fixture variables and the tests for the acceptance script, so `make test-commit` runs with no cloud access.

The spec is in the cloud-hub repo, in the dev box spec. The box is built from
code, rebuilt instead of repaired, and holds no credentials.

## Verify a built box

**Warning:** Run the script only from a machine that the box allows. The script
logs in to the box and runs Docker on it. It never prints an address or the
contents of a file.

Before the hardening slice, the box is on the LAN bridge. In that state the
rows for the home network and for a non-allowed address cannot pass. The script
reports them as SKIPPED. Add `--isolated` when the box is hardened.

1. Log in to the box once by hand, so that your machine knows the host key.
2. Set the inputs:

   ```
   export DEVBOX_HOST=<box host or address>
   export DEVBOX_USER=<login user>
   export DEVBOX_SSH_KEY=<path to your key>
   export DEVENV_IMAGE=<pinned kube-devenv image with its tag>
   export SPOKE_REPO=<https URL of a public spoke>
   ```

3. If the SSH port is not 22, set `DEVBOX_PORT`. To test a branch of the spoke, set `SPOKE_REF`.
4. Run `kube-devbox/scripts/acceptance.sh`.
5. Read the table. Each row shows PASS, FAIL or SKIPPED.
6. If a row shows FAIL, fix the cause and rebuild the box. Do not repair it by hand.
7. If the box is hardened, set these inputs and run the script again with `--isolated`:

   ```
   export HOME_TARGETS="<host:port> <host:port>"
   export INTERNET_TARGET=<host:port the box must reach>
   export PROBE_SSH=<user@host of a machine at a non-allowed address>
   ```

   `PROBE_SSH` is optional. Without it, the non-allowed address row is SKIPPED.

The exit code is 0 if no row failed, 1 if a row failed, and 2 if a tool or an
input is missing.
