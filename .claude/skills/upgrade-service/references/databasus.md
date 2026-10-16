# Databasus

Built from a release tag inside the container by `/root/build-databasus.sh <TAG>` (copy: `scripts/databasus-build.sh`), which replaces `/opt/databasus` with the new build. There is no package to install.

## Environment facts

| Item | Value |
|---|---|
| Guest | Incus container `databasus` on the Oracle host `incus` (Debian 13, arm64), unit `databasus`, port 4005 |
| Install | `/opt/databasus` (binary, `migrations/`, `ui/build/`, PostgreSQL client bundle under `assets/tools/arm/`); build source left in `/opt/databasus-src` |
| Config | `/etc/databasus.env` (mode 600): `ENV_MODE`, `DATABASUS_URL`, `DATABASE_DSN`, `APP_VERSION`. Data in `/databasus-data` |
| Database | PostgreSQL, DB `databasus` owned by role `databasus` on the Incus container `postgres` (`10.250.0.16`), same host. `DATABASE_DSN` is key=value form; read the host only with `grep -oE 'host=[^ ]+' /etc/databasus.env`, never a wider pattern |
| Omitted on purpose | The verification agent, the MySQL, MariaDB and MongoDB client tools and the embedded PostgreSQL server of the upstream image. Only PostgreSQL sources are backed up here |

Migrations run at every service start (`goose -dir ./migrations up`), so a rollback needs the DB dump, not only the snapshot.

## Check

```bash
incus exec databasus -- grep '^APP_VERSION=' /etc/databasus.env
```

`APP_VERSION` is the installed tag; `/api/v1/system/version` only echoes it and falls back to a hard-coded constant when unset. Locally:

```bash
gh release list -R databasus/databasus -L 5
gh release view <TAG> -R databasus/databasus --json body -q .body
gh api 'repos/databasus/databasus/contents/Dockerfile?ref=<TAG>' -H "Accept: application/vnd.github.raw" | grep -nE '^FROM|GOOSE_VERSION|swag@|apt-get install|tools/'
```

The script takes the Go version from `go.mod` and the goose and swag versions from the Dockerfile, so those pins follow upstream on their own. Anything else new in the Dockerfile since the installed tag (a runtime library in `apt-get install`, a tool directory under `assets/tools`, a build stage the backend needs, a Node major other than 24) means updating the script and its copy in `scripts/` before the build. Read the release notes for new required env vars and Postgres requirements.

## Rollback point

```bash
incus snapshot create databasus pre_databasus_<TAG>
incus exec postgres -- df -h /var/lib/postgresql
incus exec postgres -- su - postgres -c "pg_dump -Fc databasus -f /var/lib/postgresql/databasus-pre-<TAG>.dump && ls -lh /var/lib/postgresql/databasus-pre-<TAG>.dump"
```

The database is on the same Incus host; skip the `/etc/pve/lxc` lookup from the flow.

## Upgrade

### Resources

Record `limits.cpu` and `limits.memory` (normally `1` and `1GiB`), then:

```bash
incus config set databasus limits.memory=3GiB
incus config unset databasus limits.cpu
```

The build peaks at 2.8 GB and fails under 3 GiB.

### Build

If `scripts/databasus-build.sh` was changed in Check, push it to `/root/build-databasus.sh` in the container first. Then:

```bash
incus exec databasus -- systemctl reset-failed databasus-build 2>/dev/null
incus exec databasus -- systemd-run --unit=databasus-build -E HOME=/root \
  -p StandardOutput=truncate:/root/databasus-build.log -p StandardError=append:/root/databasus-build.log \
  /bin/bash /root/build-databasus.sh <TAG>
```

Poll every 60 s; about 13 minutes on 2 cores, longer when a new Go or Node version has to be downloaded. The service keeps running the old binary during the build. Confirm:

```bash
incus exec databasus -- grep -E '^Built Databasus|error' /root/databasus-build.log | tail -5
```

Expect `Built Databasus <TAG>` as the last line.

### Restart and verify

```bash
incus exec databasus -- sed -i 's/^APP_VERSION=.*/APP_VERSION=<TAG>/' /etc/databasus.env
incus exec databasus -- bash -c 'systemctl restart databasus && sleep 5 && systemctl is-active databasus && curl -s http://127.0.0.1:4005/api/v1/system/version && echo && curl -s -o /dev/null -w "ui %{http_code}\n" http://127.0.0.1:4005/ && journalctl -u databasus -n 20 --no-pager | cut -c1-200'
```

Expect `active`, the new tag, `ui 200` and goose migration lines without errors. Then `curl -sI https://backup.dinhhuy258.dev | head -1` from the Mac must return 200, and a manual backup of a small source such as `linkding` in the web UI must end as COMPLETED.

## Clean up

```bash
incus config set databasus limits.cpu=1 limits.memory=1GiB
incus exec databasus -- bash -c 'rm -rf /opt/databasus-src /root/databasus-build.log /root/.cache/go-build /root/.local/share/pnpm/store; df -h / | tail -1'
```

Keep `/root/go` (module cache), `/usr/local/go`, `/usr/local/node` and `/databasus-data`. No trim: the pool is a btrfs loop file.
