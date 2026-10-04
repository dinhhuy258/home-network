# Immich

Two parts on two machines: the server in a Proxmox LXC, and machine learning (ML) on a separate Oracle VM. Upgrade the server first, then ML to the same tag.

## Environment facts

| Item | Value |
|---|---|
| Server | Proxmox LXC `immich`, unit `immich-web` |
| ML | Oracle VM, unit `immich-ml` |
| Database | PostgreSQL with **pgvector**, not VectorChord. Host and name are in `DB_HOSTNAME` and `DB_DATABASE_NAME` of `/opt/immich/.env`; read them with `pct exec <ID> -- grep -e ^DB_HOSTNAME= -e ^DB_DATABASE_NAME= /opt/immich/.env` |

## Check

```bash
pct exec <ID> -- jq -r .version /opt/immich/app/package.json
pct exec <ID> -- cat /root/.immich_library_revisions
```

On the ML VM (see "Upgrade ML" for the pane), `grep -m1 '^version' /opt/immich-ml/machine-learning/pyproject.toml` prints the ML version. Stop only when both the server and ML are on the target release; if only ML lags, upgrade ML alone.

The two scripts in `scripts/` mirror upstream community-scripts `ct/immich.sh`: `immich-upgrade.sh` is its `update_script`, `immich-compile.sh` its `compile_*` functions. Each header records the upstream commit it was last matched to. Locally, read the pinned release and library pins, then list upstream changes since that commit:

```bash
curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/immich.sh -o <scratch>/ct-immich.sh
grep -E '^\s*(RELEASE|LIBHEIF_REVISION|LIBRAW_REVISION)=' <scratch>/ct-immich.sh
gh api 'repos/community-scripts/ProxmoxVE/commits?path=ct/immich.sh&per_page=10' -q '.[] | "\(.sha[0:10]) \(.commit.committer.date[0:10]) \(.commit.message | split("\n")[0])"'
gh release list -R immich-app/immich -L 5
```

If commits newer than the recorded one exist, diff `update_script` against `scripts/immich-upgrade.sh` and the `compile_*` functions against `scripts/immich-compile.sh`. Carry over new build steps, a changed plugin path, a new Node major, new libraries or changed tool pins (extism-js, binaryen). If upstream dropped its HEIC `media.repository.js` hotfix, drop ours too. Then update the sync line in both script headers.

Release notes to check for every version in between:
- removed env vars, in both the server and the ML `.env`
- the minimum Postgres version and pgvector support
- a required Node version (`.nvmrc`)

## Upgrade

### Resources

```bash
pct set <ID> --memory 8192
```

Offer it, do not require it. The extra resources only speed up the build, and the clean-up sets them back to the recorded values once it is done.

### Copy the scripts into <ID>

Run locally from the repository root:

```bash
for f in immich-compile.sh immich-upgrade.sh; do
  tmux-relay send -w <win> -t <pane-id> "rm -f /tmp/$f.b64" </dev/null >/dev/null
  base64 < .claude/skills/upgrade-service/scripts/$f | tr -d '\n' | fold -w 2000 |
    while read -r chunk || [[ -n $chunk ]]; do
      tmux-relay send -w <win> -t <pane-id> "printf %s '$chunk' >> /tmp/$f.b64" </dev/null >/dev/null
    done
done
md5 -r .claude/skills/upgrade-service/scripts/*.sh
```

Then on the host, decode, push into <ID>, remove the host copies and verify:

```bash
for f in immich-compile.sh immich-upgrade.sh; do base64 -d /tmp/$f.b64 > /tmp/$f && pct push <ID> /tmp/$f /root/$f --perms 0755 && rm -f /tmp/$f /tmp/$f.b64; done
pct exec <ID> -- bash -c 'md5sum /root/immich-*.sh; bash -n /root/immich-compile.sh && bash -n /root/immich-upgrade.sh && echo syntax-ok'
```

The checksums in <ID> must match the local ones.

### Build

```bash
pct exec <ID> -- systemd-run --unit=immich-upgrade -E HOME=/root \
  -E RELEASE=<TAG> -E LIBHEIF_REVISION=<pin> -E LIBRAW_REVISION=<pin> \
  -p StandardOutput=truncate:/root/immich-upgrade.log -p StandardError=append:/root/immich-upgrade.log \
  /root/immich-upgrade.sh
```

Poll every 90 s. Then:

```bash
pct exec <ID> -- bash -c 'grep -E "^=== " /root/immich-upgrade.log; tail -n 30 /root/immich-upgrade.log'
```

Timings: all six libraries ~15 min (libjxl 5, ImageMagick 4, libheif 2, libvips 2, libraw 1, jpegli <1); Immich build ~3 min.

`UPGRADE TO <TAG> COMPLETE` in the log means success. A `FAILED (exit N) at line L` line means the script stopped with `immich-web` down. Fix the cause and re-run the same unit with the same RELEASE. The compile step skips libraries already recorded, and the script regenerates `start.sh` if the wiped `app/` lost it. Set `FORCE_COMPILE=1` to rebuild every library.

### Verify the server

```bash
pct exec <ID> -- bash -c 'systemctl is-active immich-web; curl -s http://127.0.0.1:2283/api/server/version; grep -E "migrations|listening|plugin|Machine learning" /var/log/immich/web.log | tail'
```

Expect all of:
- `Finished running migrations`
- `Immich Server is listening ... [<TAG>]`. The `[::1]` in that line is cosmetic; `ss -ltnp` shows `*:2283`.
- `Loaded plugin: immich-plugin-core@...`
- `Machine learning server became healthy (...)`

`permission denied to vacuum "pg_authid"` (and other `pg_*` catalogs) warnings are harmless: the Immich DB user is not a superuser.

### Upgrade ML (same tag, second pane)

Ask the user whether a pane SSH'd into the Oracle ML VM is ready. Once they confirm, invoke the `ssh-shell` skill again to select that pane. Run `systemctl cat immich-ml` there first; if the unit is missing, stop and tell the user. Commands there use `sudo`.

```bash
rm -rf /tmp/machine-learning && curl -fsSL https://github.com/immich-app/immich/archive/refs/tags/<TAG>.tar.gz | tar -xz -C /tmp --strip-components=1 immich-<VER>/machine-learning
sudo systemctl stop immich-ml
cd /opt/immich-ml/machine-learning && sudo rm -rf ann immich_ml scripts && sudo cp -a /tmp/machine-learning/. . && sudo chown -R immich:immich .
sudo -u immich env HOME=/opt/immich-ml VIRTUAL_ENV=/opt/immich-ml/machine-learning/ml-venv UV_HTTP_TIMEOUT=300 \
  /usr/local/bin/uv sync --extra cpu --no-dev --active --link-mode copy -n -p python3.11 --managed-python
sudo systemctl start immich-ml
```

`<VER>` is the tag without the leading `v`. `ml-venv` and `ml_start.sh` survive the copy. Give it about 45 s, then:

```bash
curl -s http://127.0.0.1:3003/ping; sudo tail -n 15 /var/log/immich-ml/ml.log
```

- Check the ML `.env` against the release notes. v3 removed `MACHINE_LEARNING_PRELOAD__CLIP` and `__FACIAL_RECOGNITION`; they are now `__CLIP__TEXTUAL`/`__CLIP__VISUAL` and `__FACIAL_RECOGNITION__DETECTION`/`__RECOGNITION`.
- Expect `Application startup complete` and a fast preload from the existing model cache.

## Clean up

```bash
pct exec <ID> -- rm -rf /root/immich-compile.sh /root/immich-upgrade.sh /root/immich-upgrade.log /root/.local/share/pnpm/store /root/.cache /tmp/node-compile-cache
pct fstrim <ID>
```

On the Proxmox host, remove any copy leftovers with `rm -f /tmp/immich-*.sh /tmp/immich-*.sh.b64`. The copy loop removes them on success, but not when a push fails midway.

On the ML VM: `rm -rf /tmp/machine-learning`.

Keep in <ID>:
- `/opt/staging/base-images`: needed to detect library changes.
- `/root/.immich_library_revisions`: the installed library revisions.
- `/opt/binaryen-*` and the mise tools: the plugin build needs them.

## Notes

- Do not run upstream `ct/immich.sh` inside <ID>. It expects a `~/.immich` marker and an `immich-ml` unit, and it would try to install VectorChord into a non-existent local Postgres.
