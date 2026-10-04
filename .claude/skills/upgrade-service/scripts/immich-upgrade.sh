#!/usr/bin/env bash
# Upgrade the native Immich install to RELEASE, following the update_script of
# community-scripts ct/immich.sh. Postgres, Redis and ML are external, so the
# VectorChord and machine-learning steps are left out. Maintenance mode is skipped:
# the server has a single user, so stopping immich-web is enough.
# Upstream sync: community-scripts ProxmoxVE ct/immich.sh @ 5515363c84 (2026-09-29).
# Update this line whenever the script is re-matched against upstream.
set -euo pipefail

: "${RELEASE:?set RELEASE to the Immich tag, e.g. v3.2.4}"
INSTALL_DIR=/opt/immich
UPLOAD_DIR=$INSTALL_DIR/upload
SRC_DIR=$INSTALL_DIR/source
APP_DIR=$INSTALL_DIR/app
PLUGIN_DIR=$APP_DIR/plugins/immich-plugin-core
GEO_DIR=$INSTALL_DIR/geodata

trap 'echo "=== $(date +%T) FAILED (exit $?) at line $LINENO. immich-web stays stopped; re-running with the same RELEASE is safe ==="' ERR

echo "=== $(date +%T) Stopping immich-web ==="
systemctl stop immich-web

/root/immich-compile.sh

echo "=== $(date +%T) Fetching Immich $RELEASE ==="
# Keep start.sh across the wipe of APP_DIR. A previous interrupted run leaves APP_DIR
# empty, so regenerate the file when it is missing (mirrors upstream).
if grep -qs "set -a" "$APP_DIR"/bin/start.sh && grep -qs "warnings" "$APP_DIR"/bin/start.sh; then
  cp "$APP_DIR"/bin/start.sh "$INSTALL_DIR"
elif [[ ! -f "$INSTALL_DIR"/start.sh ]]; then
  cat <<EOF >"$INSTALL_DIR"/start.sh
#!/usr/bin/env bash

set -a
. ${INSTALL_DIR}/.env
set +a

/usr/bin/node --no-warnings ${APP_DIR}/dist/main.js "\$@"
EOF
  chmod +x "$INSTALL_DIR"/start.sh
fi
(
  shopt -s dotglob
  rm -rf "${APP_DIR:?}"/* "${SRC_DIR:?}"
)
mkdir -p "$SRC_DIR"
curl -fsSL --retry 3 "https://github.com/immich-app/immich/archive/refs/tags/${RELEASE}.tar.gz" |
  tar -xz --strip-components=1 -C "$SRC_DIR"

PNPM_VERSION="$(jq -r '.packageManager | split("@")[1] | split("+")[0]' "$SRC_DIR"/package.json)"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export CI=1
corepack prepare "pnpm@${PNPM_VERSION}" --activate
export PATH="/root/.local/share/pnpm/bin:$PATH"
pnpm config set --global dangerouslyAllowAllBuilds true

echo "=== $(date +%T) [1/3] Server build ==="
cd "$SRC_DIR"/server
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter immich install --frozen-lockfile
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter immich build
pnpm --filter immich --prod --no-optional deploy "$APP_DIR"
export SHARP_FORCE_GLOBAL_LIBVIPS=true
pnpm --dir "$APP_DIR/node_modules/sharp" exec npm run build

if [[ -f "$APP_DIR/helmet.json" ]]; then
  jq '.contentSecurityPolicy.directives["upgrade-insecure-requests"] = null' "$APP_DIR/helmet.json" >"$APP_DIR/helmet.json.tmp" && mv "$APP_DIR/helmet.json.tmp" "$APP_DIR/helmet.json"
fi

cp "$APP_DIR"/package.json "$APP_DIR"/bin
sed -i "s|^start|${APP_DIR}/bin/start|" "$APP_DIR"/bin/immich-admin

echo "=== $(date +%T) [2/3] Web + CLI build ==="
cd "$SRC_DIR"
echo "packageImportMethod: hardlink" >>./pnpm-workspace.yaml
unset SHARP_FORCE_GLOBAL_LIBVIPS
pnpm --filter @immich/sdk --filter immich-web --filter @immich/cli install --frozen-lockfile
pnpm --filter @immich/sdk --filter immich-web --filter @immich/cli build
pnpm --filter @immich/cli --prod --no-optional deploy "$APP_DIR"/cli
cp -a web/build "$APP_DIR"/www
cp LICENSE "$APP_DIR"
mv "$INSTALL_DIR"/start.sh "$APP_DIR"/bin

echo "=== $(date +%T) [3/3] Plugins ==="
cd "$SRC_DIR"
export MISE_TRUSTED_CONFIG_PATHS="$SRC_DIR"/mise.toml
export MISE_DISABLE_TOOLS=github:jellyfin/jellyfin-ffmpeg
mise_ok=0
for i in 1 2 3; do
  mise install && {
    mise_ok=1
    break
  }
  echo "mise install failed (attempt $i/3) - retrying"
  sleep 5
done
[[ "$mise_ok" -eq 1 ]] || { echo "=== $(date +%T) mise install failed 3 times ==="; false; }
export PATH="$(mise bin-paths 2>/dev/null | tr '\n' ':')$PATH"
if ! command -v extism-js >/dev/null 2>&1; then
  curl -fsSL --retry 3 -o /tmp/extism-js.gz "https://github.com/extism/js-pdk/releases/download/v1.6.0/extism-js-x86_64-linux-v1.6.0.gz"
  gunzip -f /tmp/extism-js.gz
  install -m 0755 /tmp/extism-js /usr/local/bin/extism-js
  rm -f /tmp/extism-js
fi
if ! command -v wasm-merge >/dev/null 2>&1; then
  BINARYEN_VERSION="$(grep -oiP 'binaryen"\s*=\s*"\Kversion_[0-9]+' "$SRC_DIR"/mise.toml | head -n1)"
  [[ -z "$BINARYEN_VERSION" ]] && BINARYEN_VERSION="version_124"
  curl -fsSL --retry 3 -o /tmp/binaryen.tar.gz "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz"
  tar -xzf /tmp/binaryen.tar.gz -C /opt
  rm -f /tmp/binaryen.tar.gz
  export PATH="/opt/binaryen-${BINARYEN_VERSION}/bin:$PATH"
fi
mise exec -- pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core install --frozen-lockfile
mise exec -- pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core build
mkdir -p "$PLUGIN_DIR"
cp -r ./packages/plugin-core/dist "$PLUGIN_DIR"/dist
cp ./packages/plugin-core/manifest.json "$PLUGIN_DIR"

echo "=== $(date +%T) Finalizing ==="
ln -sf "$APP_DIR"/resources "$INSTALL_DIR"
cd "$APP_DIR"
# grep exits 1 when nothing matches; under pipefail that must not abort the upgrade
grep -rl /usr/src . | xargs -r -n1 sed -i "s|\/usr/src|$INSTALL_DIR|g" || true
grep -rlE "'/build'" . | xargs -r -n1 sed -i "s|'/build'|'$APP_DIR'|g" || true
[[ -f "$GEO_DIR/countryInfo.txt" ]] || curl -fsSL --retry 3 -o "$GEO_DIR/countryInfo.txt" "https://download.geonames.org/export/dump/countryInfo.txt"
ln -s "$UPLOAD_DIR" "$APP_DIR"/upload
ln -sfn "$GEO_DIR" "$APP_DIR"/geodata
ln -sf "$APP_DIR"/cli/bin/immich /usr/bin/immich
ln -sf "$APP_DIR"/bin/immich-admin /usr/bin/immich-admin

# HEIC thumbnail hotfix, copied from the "MickLesk temporary patch" block in upstream
# ct/immich.sh. Remove this block as soon as the upstream sync diff shows that block gone.
python3 - <<'PY'
from pathlib import Path
p = Path('/opt/immich/app/dist/repositories/media.repository.js')
if p.exists():
    s = p.read_text()
    old = "(0, sharp_1.default)(input).metadata()"
    new = "(0, sharp_1.default)(input, { unlimited: true, limitInputPixels: false }).metadata()"
    if new in s:
        print('hotfix already there')
    elif old in s:
        p.write_text(s.replace(old, new, 1))
        print('hotfix applied')
    else:
        print('pattern not found, skipped')
PY

# Upload dir is an NFS bind mount; leave its contents alone
chown immich:immich "$INSTALL_DIR"
find "$INSTALL_DIR" -maxdepth 1 -mindepth 1 ! -name upload -exec chown -R immich:immich {} +
chown immich:immich "$UPLOAD_DIR" 2>/dev/null || true

echo "=== $(date +%T) Starting immich-web ==="
systemctl start immich-web
echo "=== $(date +%T) UPGRADE TO $RELEASE COMPLETE ==="
