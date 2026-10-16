#!/bin/bash
# Build Databasus from a release tag and install a PostgreSQL-only runtime into /opt/databasus.
# Mirrors the build stages of the upstream Dockerfile (github.com/databasus/databasus), minus the
# verification agent, the MySQL/MariaDB/MongoDB client tools and the embedded PostgreSQL server.
# Lives at /root/build-databasus.sh inside the Incus container `databasus`; keep both copies identical.
# Usage: build-databasus.sh <tag>   (for example v3.61.0)
set -euo pipefail

VERSION="${1:?usage: build-databasus.sh <tag>}"
SRC=/opt/databasus-src
APP=/opt/databasus
# systemd-run starts with no HOME, which Go needs for its module cache
export HOME=/root GOPATH=/root/go
export PATH=/usr/local/go/bin:/root/go/bin:/usr/local/node/bin:$PATH
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xz-utils libncurses6

rm -rf "$SRC"
mkdir -p "$SRC"
curl -fsSL "https://github.com/databasus/databasus/archive/refs/tags/${VERSION}.tar.gz" | tar -xz --strip-components=1 -C "$SRC"

# Toolchains: the Go version pinned in go.mod and the latest Node 24, both under /usr/local
GO_VERSION=$(awk '/^go /{print $2}' "$SRC/backend/go.mod")
if [ "$(go version 2>/dev/null | awk '{print $3}')" != "go${GO_VERSION}" ]; then
  rm -rf /usr/local/go
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" | tar -xz -C /usr/local
fi
if ! node --version 2>/dev/null | grep -q '^v24\.'; then
  NODE_TAR=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | awk '/linux-arm64\.tar\.xz$/{print $2}')
  rm -rf /usr/local/node
  mkdir -p /usr/local/node
  curl -fsSL "https://nodejs.org/dist/latest-v24.x/${NODE_TAR}" | tar -xJ --strip-components=1 -C /usr/local/node
fi
corepack enable

# Frontend
cd "$SRC/frontend"
pnpm install --frozen-lockfile
pnpm build

# Go tools pinned to the versions the upstream Dockerfile uses
GOOSE_VERSION=$(sed -n 's/^ARG GOOSE_VERSION=//p' "$SRC/Dockerfile")
SWAG_VERSION=$(sed -n 's|.*swaggo/swag/cmd/swag@\(v[0-9.]*\).*|\1|p' "$SRC/Dockerfile")
GOBIN=/usr/local/bin go install "github.com/pressly/goose/v3/cmd/goose@${GOOSE_VERSION}"
go install "github.com/swaggo/swag/cmd/swag@${SWAG_VERSION}"

# Backend
cd "$SRC/backend"
go mod download
swag init -d . -g cmd/main.go -o swagger
CGO_ENABLED=0 go build -o "$SRC/databasus" ./cmd

# Runtime: binary, migrations, UI and the PostgreSQL client bundle only
rm -rf "$APP"
mkdir -p "$APP/ui" "$APP/assets/tools/arm" /databasus-data
cp "$SRC/databasus" "$APP/databasus"
cp -r "$SRC/backend/migrations" "$APP/migrations"
cp -r "$SRC/frontend/dist" "$APP/ui/build"
cp -r "$SRC/assets/tools/arm/postgresql" "$APP/assets/tools/arm/postgresql"
chmod +x "$APP"/assets/tools/arm/postgresql/*/bin/*

echo "Built Databasus ${VERSION}"
