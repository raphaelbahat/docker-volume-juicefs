# Agent: docker-volume-juicefs development

## Critical Rules

1. **NEVER use `docker plugin create` or `docker plugin install` from a Docker Hub image to test changes.** This produces a plugin whose Unix socket is stale or disconnected — the process runs but Docker gets `context deadline exceeded` on every `VolumeDriver.*` call. This is a known Docker daemon bug.
2. **Always use the hot-swap binary method** (Debug section below) or the full `make` + `make enable` workflow (Development section below) to test changes.

## Development (full build + install)

The Makefile defaults to `PLUGIN_NAME=juicedata/juicefs` and `PLUGIN_TAG=latest`. For this fork, always override `PLUGIN_NAME`:

```shell
make PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes
make enable PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes
```

`make` builds a rootfs Docker image using the official `Dockerfile` (which includes both CE and EE `juicefs` binaries at the correct paths), exports it, and calls `docker plugin create`. `make enable` enables that plugin. This is the canonical workflow for a clean-slate test.

### Using Vagrant

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

### IMPORTANT: Always use the official Dockerfile

The `Dockerfile` in this repo places `juicefs` CE at `/bin/juicefs` and `juicefs` EE at `/usr/bin/juicefs` — these paths must match the `ceCliPath` and `cliPath` constants in `main.go`. **Never create a custom Dockerfile or base image** (e.g. `python:3.12-slim-bookworm`) for the plugin rootfs, as this will place binaries at wrong paths and cause `No help topic for 'format'` errors.

## Debug (hot-swap binary — preferred for iteration)

This is the fastest and most reliable way to test a code change on a machine that already has the plugin installed.

### Build the static binary

```shell
CC=/usr/bin/musl-gcc go build -o bin/docker-volume-juicefs --ldflags '-linkmode external -extldflags "-static"' .
```

The binary **must** be statically linked (musl) because the plugin rootfs has no shared C library.

### Hot-swap into the running plugin

1. Find the plugin's filesystem path:

```shell
docker plugin inspect raphaelbahat/juicefs:test-fixes --format '{{.Id}}'
```

2. Disable the plugin (all volumes using it must be removed or unmounted first):

```shell
docker plugin disable raphaelbahat/juicefs:test-fixes
```

3. Replace the binary:

```shell
PLUGIN_ID=$(docker plugin inspect raphaelbahat/juicefs:test-fixes --format '{{.Id}}')
sudo cp bin/docker-volume-juicefs /var/lib/docker/plugins/${PLUGIN_ID}/rootfs/docker-volume-juicefs
```

4. Re-enable:

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

## Diagnosing "context deadline exceeded"

This error means Docker cannot reach the plugin's Unix socket. Check in order:

1. Is the plugin enabled? `docker plugin ls`
2. Does the socket file exist? `sudo ls /run/docker/plugins/<ID>/`
3. Is the process running? `ps aux | grep docker-volume-juicefs`
4. Is the process listening? Try the direct socket test above.
5. If the process is running but the socket is stale (file exists but `connection refused`), the plugin was likely installed via `docker plugin install` from a pushed Docker Hub image — **this is the known bug**. Fix by using `make PLUGIN_NAME=raphaelbahat/juicefs PLUGIN_TAG=test-fixes` to rebuild properly, or by disabling, hot-swapping the binary, and re-enabling.

## Plugin build must use musl static linking

The plugin rootfs is a minimal container image with no glibc. Always compile with:

```shell
CC=/usr/bin/musl-gcc go build -o bin/docker-volume-juicefs --ldflags '-linkmode external -extldflags "-static"' .
```

Verify with `file bin/docker-volume-juicefs` — it must report `statically linked`.

## Do NOT push test plugin images to Docker Hub for local testing

Pushing via `docker plugin push` and installing via `docker plugin install` introduces the stale-socket bug. Only push to Docker Hub for distribution after validating locally via the hot-swap method.
