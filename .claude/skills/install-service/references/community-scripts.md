# Mirroring a community-scripts installer

A community-scripts reference is two scripts plus the framework libraries they call. None of them is executed. The install script is read in full, every framework call in it is resolved by reading that function's current body upstream, and the result is translated into plain commands run through `<exec>`. Nothing in this file replaces that reading.

## What to download

| File | URL |
|---|---|
| CT script | `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/<app>.sh` |
| Install script | `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/<app>-install.sh` |
| Framework entry point | `https://raw.githubusercontent.com/community-scripts/core/main/core/build.func` |

`<app>` is the file name in the user's command (`ct/caddy.sh` → `caddy`). Download all three into the scratchpad.

The framework libraries are listed in the `_CS_ENGINE_FILES` array of `build.func`, as paths relative to `https://raw.githubusercontent.com/community-scripts/core/main/`. To find the body of a function the install script calls, download the libraries named there and grep them for `<name>()`. Do not rely on remembered paths or names; the framework moves functions between files.

## What the CT script tells you

- The header assigns `APP` and `var_*` defaults (`var_cpu`, `var_ram`, `var_disk`, `var_os`, `var_version`, `var_unprivileged`, `var_tags`). Read their units from how `build.func` and its libraries consume them. A `var_*=` in front of the user's command overrides the header.
- `update_script()` is the later update flow. Read it for every state file and path it depends on (a version file in `$HOME`, the install directory it tests, the units it stops and starts, config migrations). Mirror each state file in the format the helper that writes it uses, which you find by reading that helper.

## How to translate the install script

Work top to bottom and keep the order. For every line decide which of these it is:

- **Framework housekeeping** (colour and error handling, OS detection, the network check, OS update, MOTD, the final clean-up): read the body once to see what it really does to the guest, then do the plain equivalent. In practice that is a package update and upgrade, the host's timezone and a package clean-up at the end; anything else the body does to the system, do too.
- **A package install** wrapped in the framework's quiet runner: the same packages with plain `apt-get`.
- **A toolchain or runtime helper** (Node, Python/uv, Rust, Go, PHP, Java, ffmpeg and similar): read the body and reproduce what it installs, from where, and which environment variables select the version or extra modules. Install only what the body installs for the variables the script sets.
- **A release fetch helper**: read the body for the mode the script passes, the asset selection, the extraction target, and the version file it writes and in which format. Resolve `latest` locally with `gh release view -R <owner/repo> --json tagName -q .tagName`, pick the asset for the guest's architecture with `gh release view <tag> -R <owner/repo> --json assets -q '.assets[].name'`, and write the same version file.
- **A database helper** (PostgreSQL, MariaDB, MySQL, MongoDB, Redis or Valkey, Meilisearch, ClickHouse): do not run it. The user provides the database (flow step 6). Read the body only to learn what the service expects from it (version, extensions, a created role and database) so you can tell the user, and keep only a client library the service itself needs for the chosen engine.
- **An interactive prompt** (`read -p`): the answer comes from flow step 5.
- **A generated secret** (`openssl rand` and similar): keep it inline in the heredoc that writes the config; never print it.
- **The config heredoc**: the same keys. A local database host becomes the user's host, a generated database password becomes a placeholder for `set-secret.sh`, and only the chosen engine's keys are written.
- **The unit heredoc and its enable**: byte for byte, same `User=` and `ExecStart=`.

## Notes

- community-scripts installs run as root and so do the units they write. Keep it that way unless the user asks otherwise.
- The framework also has an Incus backend, so a script's header defaults apply unchanged on the Incus host. Only the create command differs (flow step 7).
- When the service's config takes a DSN, the user's host goes in the DSN and the password is injected with `set-secret.sh --urlencode`.
