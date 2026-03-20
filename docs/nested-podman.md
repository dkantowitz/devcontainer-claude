# Nested Rootless Podman in a Devcontainer

This document describes every change required to run rootless Podman (build and run
containers) inside the devcontainer. It serves as a reference for any future delivery
spec that requires Dockerfile builds as part of the development workflow.

The knowledge was gathered through iterative troubleshooting and is consolidated here
so it does not have to be rediscovered. See the *Approaches That Failed* table at the
end for dead ends already explored.

---

## 1. Packages (Dockerfile, as root)

Install these packages with `apt-get`:

| Package | Purpose |
|---------|---------|
| `podman` | Container runtime |
| `fuse-overlayfs` | Overlay filesystem for rootless storage |
| `slirp4netns` | User-mode networking for rootless containers |
| `uidmap` | Provides `newuidmap`/`newgidmap` for user namespace ID mapping |
| `libcap2-bin` | Provides `setcap` for file capabilities |

`hadolint` (the Dockerfile linter) is also installed from GitHub releases at this step,
though it is unrelated to Podman itself.

---

## 2. File Capabilities for `newuidmap`/`newgidmap` (Dockerfile, as root)

```dockerfile
RUN chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap && \
    setcap cap_setuid+ep /usr/bin/newuidmap && \
    setcap cap_setgid+ep /usr/bin/newgidmap
```

**Why this works:** File capabilities grant `CAP_SETUID`/`CAP_SETGID` without changing
the caller's UID. The `newuidmap` ownership check passes because
`caller uid == target process uid`. Setuid changes the caller to root (uid 0), which
fails the ownership check.

**Why not `sudo` wrappers:** `sudo newuidmap` runs as root, but `newuidmap` validates
that the caller owns the target process. Root (uid 0) ≠ node (uid 1000), so it rejects
the mapping.

**Why not `CAP_SYS_ADMIN`:** Too broad — it grants mount, namespace creation, hostname
changes, BPF access, and dozens of other permissions to every process in the container.

---

## 3. crun Upgrade (Dockerfile, as root)

Debian Bookworm ships crun 1.8, which fails with `EROFS` when trying to write
`/proc/sys/net/ipv4/ping_group_range` inside nested containers (Docker mounts `/proc/sys`
read-only). crun 1.9+ gracefully ignores this error.

```dockerfile
ARG CRUN_VERSION=1.26
RUN curl -fsSL "https://github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-amd64" \
      -o /usr/local/bin/crun && chmod +x /usr/local/bin/crun
```

---

## 4. Podman User Config (Dockerfile, as USER node)

```dockerfile
RUN mkdir -p /home/node/.config/containers && \
    printf '[storage]\ndriver = "vfs"\n' > /home/node/.config/containers/storage.conf && \
    printf '[engine]\nruntime = "/usr/local/bin/crun"\n\n[engine.runtimes]\ncrun = ["/usr/local/bin/crun"]\n' > /home/node/.config/containers/containers.conf && \
    printf '\n[containers]\ndefault_sysctls = []\n' >> /home/node/.config/containers/containers.conf
ENV BUILDAH_ISOLATION=chroot
```

| Setting | Value | Reason |
|---------|-------|--------|
| `storage.driver` | `vfs` | No FUSE needed in an unprivileged container |
| `engine.runtime` | `/usr/local/bin/crun` | Points to the upgraded binary (1.26) |
| `containers.default_sysctls` | `[]` (empty) | Cannot write `/proc/sys` in nested containers |
| `BUILDAH_ISOLATION` | `chroot` | Uses chroot instead of full namespace isolation for `RUN` steps during builds, avoiding `CAP_SYS_ADMIN` requirement for `sethostname` in new UTS namespaces |

---

## 5. User Namespace ID Mapping (Dockerfile, as root)

```dockerfile
RUN usermod --add-subuids 100000-165535 --add-subgids 100000-165535 node
```

This allocates a subordinate UID/GID range for the `node` user, which Podman needs to
set up user namespaces for rootless containers.

---

## 6. Custom Seccomp Profile (`seccomp.json`)

The default Docker seccomp profile blocks several syscalls that Podman needs for
namespace setup and overlay mounts. The custom profile is based on Docker's default
with these syscalls added **unconditionally** (no argument restrictions):

```
clone, clone3, fsconfig, fsmount, fsopen, fspick,
keyctl, mount, mount_setattr, move_mount, open_tree,
pivot_root, setns, umount, umount2, unshare
```

`keyctl` is needed by container runtimes for kernel keyring management during namespace
setup.

The profile is referenced in `devcontainer.json`:

```json
"--security-opt", "seccomp=${localWorkspaceFolder}/.devcontainer/seccomp.json"
```

---

## 7. Device and Capabilities (`devcontainer.json` runArgs)

```json
"--cap-add=NET_ADMIN",
"--cap-add=NET_RAW",
"--device=/dev/net/tun",
```

| Setting | Reason |
|---------|--------|
| `NET_ADMIN` | Required for the devcontainer firewall (`iptables`/`ipset`) — **not** for Podman |
| `NET_RAW` | Required for `ping` and the firewall |
| `/dev/net/tun` | Required by `slirp4netns` for user-mode networking in nested containers |

---

## 8. Firewall Allowlist Entries

For `podman build` to reach registries and package repositories, these hosts must be in
`.devcontainer/allowlist`:

| Host | Purpose |
|------|---------|
| `registry-1.docker.io` | Docker Hub registry |
| `auth.docker.io` | Docker Hub authentication |
| `production.cloudflare.docker.com` | Docker Hub CDN |
| `r2.cloudflarestorage.com` | Docker Hub storage backend |
| `deb.debian.org` | Debian apt repositories (for `apt-get` in build stages) |
| `security.debian.org` | Debian security updates |

---

## 9. Approaches That Failed

| Approach | Why it failed |
|----------|---------------|
| Setuid `newuidmap` (default) | Docker blocks setuid from gaining capabilities |
| `sudo` wrappers for `newuidmap` | `newuidmap` rejects root callers (ownership check: root uid 0 ≠ node uid 1000) |
| Direct `/proc/PID/uid_map` write | Kernel requires `CAP_SETUID` in parent user namespace |
| `CAP_SYS_ADMIN` | Works but too broad — grants dozens of unrelated permissions to every process |
| `--userns=host` Podman config | Podman still needs `newuidmap` for internal namespace setup |
| `BUILDAH_ISOLATION=rootless` (default) | Requires `CAP_SYS_ADMIN` for `sethostname` in UTS namespace |
| crun 1.8 (Debian Bookworm default) | `EROFS` on `/proc/sys/net/ipv4/ping_group_range` write inside nested container |

---

## Summary: Files Changed

| File | Change |
|------|--------|
| `Dockerfile` | Add Podman packages, file capabilities, crun upgrade, user config, subuid/subgid |
| `seccomp.json` | Custom profile with namespace and mount syscalls unblocked |
| `devcontainer.json` | Add `--cap-add=NET_ADMIN`, `--cap-add=NET_RAW`, `--device=/dev/net/tun`, seccomp reference |
| `allowlist` | Add Docker Hub and Debian apt hosts |
