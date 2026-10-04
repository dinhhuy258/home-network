# Vaultwarden

## Environment facts

| Item | Value |
|---|---|
| Guest | Proxmox LXC `vaultwarden`, unit `vaultwarden` |
| Database | PostgreSQL. Host and name are in `DATABASE_URL` of `/opt/vaultwarden/.env`; read them with `pct exec <ID> -- sed -nE 's#.*@([^/]+)/([^?]+).*#host=\1 db=\2#p' /opt/vaultwarden/.env`, which masks the password |
| Rust | rustup in `/root/.cargo/bin`, not on PATH for `pct exec` |

## Check

```bash
pct exec <ID> -- /opt/vaultwarden/bin/vaultwarden --version
pct exec <ID> -- cat /opt/vaultwarden/web-vault/version.json
```

Stop only when both the binary and the web-vault are on the latest release; if only the web-vault lags, skip the build and install the web-vault alone.

Locally:

```bash
gh release list -R dani-garcia/vaultwarden -L 3
gh release list -R dani-garcia/bw_web_builds -L 3
gh api 'repos/dani-garcia/vaultwarden/contents/rust-toolchain.toml?ref=<TAG>' -H "Accept: application/vnd.github.raw"
gh release view <WV_TAG> -R dani-garcia/bw_web_builds --json assets -q '.assets[].name'
```

The toolchain file tells you which Rust version the build will download, and therefore which older pinned toolchains the clean-up can remove. The asset list confirms the web-vault file name. Read the release notes for client-compatibility notes ("required for clients vX+").

## Upgrade

### Resources (optional)

```bash
pct set <ID> --cores 4 --memory 6144
```

Offer it, do not require it. The extra resources only speed up the build, and the clean-up sets them back to the recorded values once it is done.

### Build

Fetch the source first:

```bash
pct exec <ID> -- bash -c 'rm -rf /tmp/vaultwarden-src && mkdir -p /tmp/vaultwarden-src && curl -fsSL https://github.com/dani-garcia/vaultwarden/archive/refs/tags/<TAG>.tar.gz | tar xz --strip-components=1 -C /tmp/vaultwarden-src'
```

```bash
pct exec <ID> -- systemd-run --unit=vw-build --working-directory=/tmp/vaultwarden-src \
  -p StandardOutput=truncate:/tmp/vw-build.log -p StandardError=append:/tmp/vw-build.log \
  -E PATH=/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin -E HOME=/root -E VW_VERSION=<TAG> \
  -E CARGO_PROFILE_RELEASE_LTO=false -E CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  /root/.cargo/bin/cargo build --features postgresql --release
```

Build with **`--features postgresql` only**; this install uses only PostgreSQL.

Poll every 60 s. Then:

```bash
pct exec <ID> -- bash -c 'grep -E "^error|Finished" /tmp/vw-build.log | tail -5; /tmp/vaultwarden-src/target/release/vaultwarden --version'
```

About 6 minutes, plus the toolchain download on a new Rust version.

### Install binary and web-vault, then verify

```bash
pct exec <ID> -- bash -c 'cd /tmp && curl -fsSLO https://github.com/dani-garcia/bw_web_builds/releases/download/<WV_TAG>/bw_web_<WV_TAG>.tar.gz && systemctl stop vaultwarden && cp /tmp/vaultwarden-src/target/release/vaultwarden /opt/vaultwarden/bin/vaultwarden && chown vaultwarden:vaultwarden /opt/vaultwarden/bin/vaultwarden && rm -rf /opt/vaultwarden/web-vault && mkdir -p /opt/vaultwarden/web-vault && tar xzf bw_web_<WV_TAG>.tar.gz --strip-components=1 -C /opt/vaultwarden/web-vault && chown -R root:root /opt/vaultwarden/web-vault && rm bw_web_<WV_TAG>.tar.gz && systemctl start vaultwarden && sleep 5 && systemctl is-active vaultwarden && /opt/vaultwarden/bin/vaultwarden --version && cat /opt/vaultwarden/web-vault/version.json && journalctl -u vaultwarden -n 20 --no-pager'
```

Expect `Rocket has launched from http://0.0.0.0:8000` in the log. Then:

```bash
pct exec <ID> -- bash -c 'curl -s http://127.0.0.1:8000/api/config | grep -oE "\"version\":[^,}]*" | head -1; curl -s -o /dev/null -w "web %{http_code}\n" http://127.0.0.1:8000/'
```

`/api/config` reports the emulated Bitwarden server version (the "Server: Vaultwarden X" line in client error reports), not the Vaultwarden release number.

## Clean up

```bash
pct exec <ID> -- rm -rf /tmp/vaultwarden-src /tmp/vw-build.log
pct exec <ID> -- /root/.cargo/bin/rustup toolchain list
pct exec <ID> -- /root/.cargo/bin/rustup toolchain uninstall <old pinned versions>
pct fstrim <ID>
```

Keep `stable` (rustup default) and the toolchain the current release pins; remove older pinned ones.
