# Frigate

Frigate is not a native install: it runs as Docker Compose inside the LXC, so this reference replaces the systemd parts of the flow (no unit, no build, no `systemd-run`).

## Environment facts

| Item | Value |
|---|---|
| Guest | Proxmox LXC `frigate` on pve2 (reach it from the pve1 pane with `ssh -o BatchMode=yes pve2 '...'`) |
| Service | Docker Compose project `/opt/frigate/docker-compose.yml`, container `frigate`, image `ghcr.io/blakeblackshear/frigate:stable`; there is no systemd unit, so step 2 checks the container instead |
| Config and database | `/opt/frigate/config/config.yml` and the SQLite `frigate.db` next to it (mounted as `/config`); no external database |
| Media | `/mnt/frigate`, an NFS share bind-mounted as `mp0` with `shared=1` |
| Secrets | The compose file holds secret env lines; never `cat` it, read it with `grep -vE 'PASSWORD|SECRET|TOKEN'` |
| Logging | The compose file caps json-file logs at `max-size: 10m`, `max-file: "3"`; without it the container log grows unbounded |

## Find the host and the guest

```bash
pct list | awk -v n=frigate '$NF == n {print $1}'
pct exec <ID> -- bash -c 'cd /opt/frigate && docker compose config -q && echo compose-ok; docker ps --filter name=frigate --format "{{.Image}} {{.Status}}"'
```

## Check

```bash
pct exec <ID> -- docker exec frigate python3 -c 'from frigate.version import VERSION; print(VERSION)'
pct exec <ID> -- bash -c 'df -h /; du -sh /var/lib/docker/containers /var/lib/containerd 2>/dev/null'
uname -r    # on pve2
```

Locally:

```bash
gh release list -R blakeblackshear/frigate -L 5
gh release view <TAG> -R blakeblackshear/frigate --json body -q .body > <scratchpad>/notes-<TAG>.md
```

Read every release's notes between the installed and the target version and check the breaking changes against `config.yml` (detectors, `hwaccel_args`, go2rtc streams, genai, zones and masks) and the kernel minimum. The image needs about 7 GB in `/var/lib/containerd` during the pull on top of the old one; grow the rootfs first if the free space is below that (`pct resize <ID> rootfs +16G`).

## Rollback point

`pct snapshot` fails with "snapshot feature is not available" because of the `mp0` bind mount. The only cheap rollback is a copy of the config and database before the first start of the new version, which may migrate both:

```bash
pct exec <ID> -- bash -c 'cd /opt/frigate/config && cp -a config.yml config.yml.bak-pre-<TAG> && cp -a frigate.db frigate.db.bak-pre-<TAG>'
```

To roll back, pin the old image tag in the compose file and restore both copies.

## Upgrade

```bash
pct exec <ID> -- bash -c 'cd /opt/frigate && docker compose pull -q && docker image inspect ghcr.io/blakeblackshear/frigate:stable --format "{{.Id}} {{.Created}}" && echo pull-done'
```

The pull takes a few minutes; use `--timeout 590` on the `tmux-relay send`. Then recreate the container, which also drops the old container log:

```bash
pct exec <ID> -- bash -c 'cd /opt/frigate && docker compose up -d && sleep 120 && docker ps --format "{{.Names}} {{.Status}}" && docker exec frigate python3 -c "from frigate.version import VERSION; print(VERSION)" && docker logs frigate 2>&1 | grep -iE "migrat|error|exception|traceback" | grep -viE "password|user:" | cut -c1-160 | tail -25'
```

Expect `frigate Up 2 minutes (healthy)` and the target version (for example `0.18.0-77a66e7`). `ffmpeg.<camera>.detect ERROR ... rtsp://127.0.0.1:8554/<camera>_sub ... 404 Not Found` only means go2rtc cannot reach that camera; it is expected while the cameras in `config.yml` are not on the network, and not an upgrade failure.

## Clean up

```bash
pct exec <ID> -- bash -c 'docker image prune -f | tail -1; df -h / | tail -1'
pct fstrim <ID>
```

The prune removes the old dangling image (about 1.8 GB). Remove the `*.bak-pre-<TAG>` copies from step 4 once the user is happy with the new version.
