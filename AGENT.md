# Agent: docker-volume-juicefs development

## Critical Rules

1. **NEVER use `docker plugin install` from a Docker Hub image to test changes.** This produces a plugin whose Unix socket is stale or disconnected — the process runs but Docker gets `context deadline exceeded` on every `VolumeDriver.*` call. This is a known Docker daemon bug.
2. **Always use the hot-swap binary method** (Debug section below) or the full `make` + `make enable` workflow (Development section below) to test changes.
3. **Never create a custom Dockerfile or base image** (e.g. `python:3.12-slim-bookworm`) for the plugin rootfs. Always use the official `Dockerfile` in this repo, which correctly handles CE/EE binary placement and base-image quirks.

## Development (full build + install)

The Makefile defaults to `PLUGIN_NAME=juicedata/juicefs` and `PLUGIN_TAG=latest`. For this fork, always override `PLUGIN_NAME`:

```shell
make PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes
make enable PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes
```

`make` builds a rootfs Docker image using the `Dockerfile`, exports it, and calls `docker plugin create`. `make enable` enables that plugin. This is the canonical workflow for a clean-slate build.

The Makefile uses `--no-cache` by default to prevent Docker layer caching from serving stale binaries. You can pin a specific CE version:

```shell
make PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes JUICEFS_CE_VERSION=1.3.1
```

Optionally, pass `JUICEFS_CE_SHA256` to verify the downloaded tarball integrity:

```shell
make PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes \
  JUICEFS_CE_VERSION=1.3.1 \
  JUICEFS_CE_SHA256=<sha256-of-tarball>
```

### Using Vagrant (optional but recommended)

Developing with Vagrant provides an isolated, reproducible environment that doesn't affect your host Docker setup. This is especially recommended when modifying the Dockerfile or testing plugin lifecycle (create/enable/disable/remove), since mistakes can leave stale plugin state on the host.

Boot up vagrant environment:

```shell
vagrant up
vagrant ssh
```

Inside vagrant:

```shell
export WORKDIR=~/go/src/docker-volume-juicefs
mkdir -p $WORKDIR
rsync -avz --exclude plugin --exclude .git --exclude .vagrant /vagrant/ $WORKDIR/
cd $WORKDIR
make PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes
make enable PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes
docker volume create -d raphaelbahat/juicefs:test-fixes -o name=$JFS_VOL -o metaurl=$JFS_META_URL jfsvolume
docker run -it -v jfsvolume:/opt busybox ls /opt
```

### CE/EE binary paths

The `main.go` constants define where each binary must live:

| Constant | Path | Edition | Used by |
|----------|------|---------|---------|
| `ceCliPath` | `/bin/juicefs` | Community Edition | `ceMount()` — calls `juicefs format` then `juicefs mount` |
| `cliPath` | `/usr/bin/juicefs` | Enterprise Edition | `eeMount()` — calls `juicefs auth` then `juicefs mount` |

The Dockerfile includes a build-time verification step that confirms the downloaded CE binary matches `JUICEFS_CE_VERSION`. If the version doesn't match, the build fails immediately.

## Debug (hot-swap binary — debug only, not for release or production)

The hot-swap method replaces only the `docker-volume-juicefs` Go binary inside the installed plugin. It does NOT rebuild the rootfs image, update the CE/EE JuiceFS binaries, or update `config.json`. **Only use this for rapid iteration during development.** For any release or production deployment, always do a full `make` build.

### Build the static binary

```shell
CC=/usr/bin/musl-gcc go build -o bin/docker-volume-juicefs --ldflags '-linkmode external -extldflags "-static"' .
```

The binary **must** be statically linked (musl) because the plugin rootfs has no shared C library.

### Hot-swap into the running plugin

1. Disable the plugin (all volumes using it must be removed or unmounted first):

```shell
docker plugin disable raphaelbahat/juicefs:test-fixes
```

2. Replace the binary:

```shell
PLUGIN_ID=$(docker plugin inspect raphaelbahat/juicefs:test-fixes --format '{{.Id}}')
sudo cp bin/docker-volume-juicefs /var/lib/docker/plugins/${PLUGIN_ID}/rootfs/docker-volume-juicefs
```

3. Re-enable:

```shell
docker plugin enable raphaelbahat/juicefs:test-fixes
```

### Verify the plugin is responsive

```shell
# Quick check — should list volumes without error
docker volume ls

# Direct socket test
PLUGIN_ID=$(docker plugin inspect raphaelbahat/juicefs:test-fixes --format '{{.Id}}')
sudo python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/run/docker/plugins/${PLUGIN_ID}/jfs.sock')
s.sendall(b'GET /Plugin.Activate HTTP/1.0\r\nHost: localhost\r\n\r\n')
print(s.recv(4096).decode())
s.close()
"
```

If you see `{"Implements": ["VolumeDriver"]}`, the plugin is healthy. If you get `connection refused` or `No such file or directory`, the socket is stale — the plugin did not start correctly.

### Enable debug logging

```shell
docker plugin disable raphaelbahat/juicefs:test-fixes
docker plugin set raphaelbahat/juicefs:test-fixes DEBUG=1
docker plugin enable raphaelbahat/juicefs:test-fixes
```

**Security warning:** DEBUG=1 causes the full `juicefs format` and `juicefs mount` commands (including `--access-key`, `--secret-key`, and the PostgreSQL password in the metaurl) to be logged to journalctl. Disable debug logging before production use.

## Viewing plugin logs

The plugin's stdout/stderr are redirected to the Docker daemon log. Entries have a `plugin=<ID>` suffix.

```shell
# Via journalctl — filter by plugin ID
PLUGIN_ID=$(docker plugin inspect raphaelbahat/juicefs:test-fixes --format '{{.Id}}')
journalctl -u docker.service -f | grep "plugin=${PLUGIN_ID}"

# Via runc — find the plugin container ID first
sudo runc --root /run/docker/runtime-runc/plugins.moby list
# Then exec into it to read the JuiceFS log:
sudo runc --root /run/docker/runtime-runc/plugins.moby exec <CONTAINER_ID> cat /var/log/juicefs.log
```

NOTE: the runtime root directory could be `moby-plugins` instead of `plugins.moby` in some Docker versions.

## Plugin config.json

The `config.json` in this repo defines the plugin's capabilities, mount points, and environment. When modifying it:

- **Mounts** define host directories bind-mounted into the plugin. The `cache` mount maps `/var/lib/juicefs-cache` on the host to `/var/jfsCache` inside the plugin, persisting the JuiceFS block cache across plugin updates.
- **After `make`**, `config.json` is copied from the repo to `./plugin/config.json` and used by `docker plugin create`. Any changes to the repo's `config.json` take effect on the next `make` build.
- **After a hot-swap**, the installed plugin's `config.json` at `/var/lib/docker/plugins/<ID>/config.json` is NOT updated. If you need to change mounts or env vars, do a full `make` rebuild, or manually edit the installed config.json while the plugin is disabled:

```shell
docker plugin disable raphaelbahat/juicefs:test-fixes
# Edit /var/lib/docker/plugins/<ID>/config.json
docker plugin enable raphaelbahat/juicefs:test-fixes
```

## Diagnosing common errors

### "No help topic for 'format'"

The binary at `/bin/juicefs` is the EE binary instead of CE. Rebuild with `make` (which uses `--no-cache`) and verify the Dockerfile includes the `/bin` symlink fix.

### "context deadline exceeded"

Docker cannot reach the plugin's Unix socket. Check in order:

1. Is the plugin enabled? `docker plugin ls`
2. Does the socket file exist? `sudo ls /run/docker/plugins/<ID>/`
3. Is the process running? `ps aux | grep docker-volume-juicefs`
4. Is the process listening? Try the direct socket test above.
5. If the process is running but the socket is stale, the plugin was likely installed via `docker plugin install` from a pushed Docker Hub image. Fix by doing a full `make` rebuild.

### "exit status 3" on mount

The JuiceFS mount command failed. Check the plugin logs (see "Viewing plugin logs") for the actual error. Common causes: S3 credentials invalid, metadata database unreachable, or encryption key missing (`JFS_RSA_PASSPHRASE` environment variable not set).

## Plugin build must use musl static linking

The plugin rootfs is a minimal container image with no glibc. Always compile with:

```shell
CC=/usr/bin/musl-gcc go build -o bin/docker-volume-juicefs --ldflags '-linkmode external -extldflags "-static"' .
```

Verify with `file bin/docker-volume-juicefs` — it must report `statically linked`.

## cleanupCache behavior

The `Remove()` function only calls `cleanupCache(v)` when the volume was created with the `cleanup-cache` driver option set to `true`. This prevents accidental cache deletion on routine volume removal. The cache is persisted on the host at `/var/lib/juicefs-cache/<volume-uuid>/`.

## Do NOT push test plugin images to Docker Hub for local testing

Pushing via `docker plugin push` and installing via `docker plugin install` introduces the stale-socket bug. Only push to Docker Hub for distribution after validating locally via the hot-swap method.
