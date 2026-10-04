---
name: install-service
description: Install a new self-hosted service natively in a fresh Proxmox LXC or Incus container, mirroring the reference the user gives (a community-scripts ct/<app>.sh, upstream install docs). Use when the user asks to install, deploy or set up a new service.
argument-hint: <service> [reference]
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read, AskUserQuestion, Skill
---

# Install a native service

One new guest per service, built by mirroring the user's reference step by step.

## Pick the reference

- The service is the first skill argument. If it is missing, ask with AskUserQuestion.
- The reference is everything after the service. It can be a community-scripts URL such as `https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/caddy.sh`, a URL to the project's install docs, or notes the user pastes.
- For a Proxmox community-scripts reference (community-scripts/ProxmoxVE), follow `references/community-scripts.md`: download `ct/<app>.sh` and `install/<app>-install.sh` to the scratchpad and read both.
- If there is no reference, build one from the project itself. Find the repository (ask the user for the URL when the service name is ambiguous), then read with `gh` and `curl` to the scratchpad: the README, the install or self-hosting docs, the `Dockerfile` or a packaging recipe for the runtime, build steps and start command, and the latest release's assets. From those, write a proposed install flow: OS, runtime and version, how the release is fetched, install directory, config file and its keys, the service unit and the user it runs as, the port, the state files a later upgrade would need. Show it and ask the user to approve or amend it with AskUserQuestion. The approved flow is the reference for the rest of this skill. Without a repository or docs to read, stop; do not install from memory.
- Any other reference (install docs, a vendor script, a gist) is saved to the scratchpad with `curl` and read there with Read, never through WebFetch, so nothing is summarised away and the file can be searched again during the install.
- Never run the reference command itself, on the host or in the guest. Mirror it: same OS and version, the latest release unless the reference pins one, the same install directory, the same config keys, the same unit and the same user (root if the reference uses root). Drop only the framework parts and the bundled database; do not add improvements such as a dedicated service user or version pinning.

## Operating rules

- Every comment or description written to a server must be in English.
- Never print a secret in the conversation: never `cat` a config that holds one, never put one on a command line, and never ask the user to paste one into the chat. Secrets enter the guest only through the path in step 8.
- No database inside the guest. PostgreSQL, MySQL, MariaDB, MongoDB, Redis and similar are provided by the user (step 6). Install only the client library, driver or build feature of the engine the user chose, never the others'.
- Create the guest with the resources the user picked in step 4. A build boost is temporary and is reverted in step 10 even after a failed run.
- Ask once, up front (steps 4 to 6), then run through the install without further questions unless something stops it.
- When a step has several things to ask, put them all in one AskUserQuestion call, with related choices bundled into one option each. Never ask one value, act, then ask the next.
- A `tmux-relay send` that ends in `Timeout: idle pattern not matched` (other than at the `set-secret.sh` prompt) means the command is still running in the pane. Send nothing more to that pane; ask the user what the pane shows. Every `incus stop`/`incus restart` carries `--timeout 30`, or `--force` for a guest that holds no data yet.

## Runtimes

`<exec>` in the flow means "run inside the guest": `pct exec <ID> --` on Proxmox, `incus exec <name> --` on Incus. The Incus host is arm64, so release assets, Node builds and wheels must match `uname -m`; the Proxmox nodes are x86_64.

## Flow

### 1. Select the pane

Invoke the `ssh-shell` skill and let the user select a pane SSH'd into the host that will own the new guest.

### 2. Identify the runtime and the host (read-only)

```bash
hostname; uname -m; command -v pct incus
```

Exactly one of `pct` and `incus` must be present; that is the runtime. **Stop and ask** if both or neither are found; do not try another pane on your own. Then read the host's capacity and conventions:

```bash
# Proxmox
nproc; free -m; pvesm status; pct list
pvesh get /cluster/nextid                                                      # proposed ID
grep -h '^net0:' /etc/pve/nodes/*/lxc/*.conf | grep -oE 'ip=[^,/]+' | sort -t. -k4 -n   # addresses in use cluster-wide
pct config <running-ID> | grep -E '^(net0|nameserver|searchdomain|swap|onboot|startup|unprivileged|features):'   # the node's conventions
# Incus
nproc; free -m; incus storage info default; incus list -c ns4tc
incus network get incusbr0 ipv4.address
incus config show <running-name> | grep -E 'limits\.|boot\.autostart'
```

Add up the cores and memory already allocated to running guests; the recommendation in step 4 must leave headroom on the host.

### 3. Read the reference and write the plan (read-only)

From the reference, derive and show the user a plan table: OS and version, release source and version (run `gh release view -R <owner/repo> --json tagName -q .tagName` locally for `latest`), runtime tooling (Node major, Python, Rust, Go, PHP), install directory, config file and every key it gets, service unit and the user it runs as, listening port, state files the reference's update flow relies on (read from its update function and the helper that writes them), secrets, database engines the service supports, and the reference's sizing defaults. Also list the `read -p` prompts of the install script (public URL, admin e-mail); their answers are gathered in step 5.

Read the project's release notes for the target version when the reference is older than it: new required env vars, a changed minimum database version, a new Node major.

### 4. Resources: recommend, then let the user choose

Recommend a size and let the user choose. Start from the reference: the community-scripts header carries cores, RAM in MiB and disk in GiB, other projects document minimums. Compare with the headroom from step 2 and present three options with AskUserQuestion, each spelling out cores, RAM and disk: the recommended one first and labelled "(Recommended)", a leaner one, a roomier one. No option may exceed the host's core count or its free memory.

In the same AskUserQuestion, when the install compiles or bundles something (cargo, `pnpm`/`next build`, `uv sync` with native wheels, `go build`, a web UI build), ask a second question: raise the guest to N cores / M MiB for the build and set it back at clean-up, yes (recommended) or no. The boost stays within the host's cores and free memory. Note both answers; step 7 creates the guest with the chosen size, step 8 applies the boost.

### 5. Guest identity

Propose and confirm in one AskUserQuestion round:

- Name and hostname: the service name in lowercase (the community-scripts `APP` lowercased) unless the user says otherwise.
- Proxmox: the ID from `pvesh get /cluster/nextid`, and a static address in the node's subnet, proposing the lowest free last octet. An address is free when `grep -l "ip=<IP>/" /etc/pve/nodes/*/lxc/*.conf` prints nothing and `ping -c1 -W1 <IP>` gets no reply. Gateway, nameserver, searchdomain, swap, onboot and startup follow the conventions read in step 2.
- Incus: a static address on `incusbr0`, proposing the lowest free one from `incus list -c n4`.
- Answers to the install script's prompts (public URL, admin e-mail).

### 6. Database and secrets

Decide from the reference whether the service needs a database, cache or search engine: the install script sets one up or installs one (PostgreSQL, MySQL or MariaDB, MongoDB, Redis or Valkey, Meilisearch, ClickHouse), or the docs say so. If it does:

- Tell the user this skill does not create databases: they create the database and the role themselves and share the connection details. Give them exactly what the service needs in a fenced block: engine, minimum version, required extensions (for example `pgvector`), and the statements to run with a placeholder password, such as `CREATE ROLE <svc> LOGIN PASSWORD '<choose>'; CREATE DATABASE <svc> OWNER <svc>;` plus any `CREATE EXTENSION`.
- If the service supports more than one engine, ask which one with AskUserQuestion, listing only the engines the service supports. Only the chosen engine's client library, driver or build feature is installed (`--features postgresql`, `php-pgsql`, `psycopg`, `pymysql`); never the others'. The same goes for the config: write only the chosen engine's keys.
- Ask for the non-secret details: host, port, database name, user, and SSL mode when the service has such a key. Never ask for the password.
- List every secret the service needs and sort it: user-provided (database password, SMTP password, API keys) or generated (`ENCRYPTION_KEY`, `SECRET_KEY`, admin tokens). Generated secrets are produced inside the guest by the install commands (`openssl rand -base64 32` inline in the heredoc) and are never printed. User-provided secrets go in through step 8.

### 7. Create the guest

Proxmox. The template is the newest one matching the reference's OS and version:

```bash
pveam update >/dev/null; pveam available --section system | grep -E '<os>-<version>'
pveam download local <template>
pct create <ID> local:vztmpl/<template> --hostname <name> --ostype <os> --unprivileged <var_unprivileged> --features nesting=1 \
  --cores <C> --memory <M> --swap <swap> --rootfs local-lvm:<G> \
  --net0 name=eth0,bridge=vmbr0,ip=<IP>/24,gw=<GW>,type=veth --nameserver <NS> --onboot 1 --start 1
pct exec <ID> -- bash -c 'until ping -c1 -W1 deb.debian.org >/dev/null 2>&1; do sleep 1; done; echo net-ok'
```

No `--password`: the console login is not used and `pct exec` does not need one. `keyctl=1` is only for Docker, which this skill does not install. Bind mounts (`--mp0`) are added only when the user asks for one.

Incus. The pool is btrfs, so the root size is a quota:

```bash
incus image info images:<os>/<version> | head -5                                   # the architecture follows the host
incus init images:<os>/<version> <name> -c limits.cpu=<C> -c limits.memory=<M>MiB -c boot.autostart=true -d root,size=<G>GiB
incus config device override <name> eth0 ipv4.address=<IP>                         # before the first start: no restart needed
incus start <name>
incus list '^<name>$' -c ns4                                                        # must show the static address
incus exec <name> -- bash -c 'for i in $(seq 60); do getent hosts deb.debian.org >/dev/null && echo net-ok && break; sleep 1; done'
```

Create with `init`, not `launch`: a container that is already running needs `incus restart` to pick up the address, and a restart sent while systemd is still booting waits forever for a clean shutdown. The minimal Incus images ship without `ping`, so the network wait uses `getent` and gives up after 60 s.

Base preparation in either guest, which is what the community-scripts housekeeping functions amount to:

```bash
<exec> bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade'
<exec> bash -c 'ln -sf /usr/share/zoneinfo/<host-tz> /etc/localtime && echo <host-tz> > /etc/timezone'   # <host-tz> from timedatectl on the host
```

### 8. Install (mirror the reference)

Translate the reference step by step: community-scripts installs as `references/community-scripts.md` describes, docs as written. Record the versions you install.

Build boost. If step 4 agreed to one, record the current values first and raise them before the long steps:

```bash
pct config <ID> | grep -E '^(cores|memory):'                                     # Proxmox: record before raising
incus config get <name> limits.cpu; incus config get <name> limits.memory        # Incus: record before raising
pct set <ID> --cores N --memory MB                                               # Proxmox
incus config set <name> limits.cpu=N limits.memory=<N>MiB                       # Incus: the unit is required; a bare number is bytes
```

Long steps. Run anything long (a compile, `npm install`, `uv sync`) as a transient systemd unit in the guest. A background job started through `<exec>` dies when the exec returns. The executable must be an absolute path, because `systemd-run` resolves it before applying `-E PATH`.

```bash
<exec> systemctl reset-failed <unit> 2>/dev/null    # a failed previous run blocks the unit name
<exec> systemd-run --unit=<unit> -E HOME=/root <more -E/-p as the step needs> \
  -p StandardOutput=truncate:<log> -p StandardError=append:<log> \
  <absolute command>
```

Wait with this loop and nothing else. An empty read means the pane was busy, not that the unit finished, so only a non-empty value other than `active` ends the loop:

```bash
while :; do s=$(tmux-relay send -w <win> -t <pane-id> "<exec> systemctl is-active <unit>" </dev/null 2>/dev/null | tail -1 | tr -d '[:space:]'); [[ -z "$s" || "$s" == active ]] || break; sleep <poll>; done; echo "unit ended: $s"
```

Run the loop with the Bash tool's `run_in_background` option: a foreground Bash call is killed after at most 10 minutes, while the background call keeps running and notifies you when it exits. Do not send anything else to that pane while the loop runs. `inactive` means the unit finished; confirm success from the log. `failed` means read the log.

Config file. Write it with the reference's keys and the user's answers. Where a user-provided secret belongs, write a placeholder such as `__DB_PASSWORD__` or `__SMTP_PASSWORD__`; generated secrets are generated inline. Set the mode and owner before any secret goes in: `chmod 600` and the owner the unit runs as.

Secret entry. The user types each secret into the pane; it never passes through the conversation, a command line or the shell history. Copy `scripts/set-secret.sh` into the guest (see "Copy a file into the guest"), then for every placeholder:

1. Send `<exec> /root/set-secret.sh <config> <placeholder> [--urlencode]` with `--timeout 5`. tmux-relay answers `Timeout: idle pattern not matched`. That is expected: the script is waiting at its prompt in the pane, and the timeout does not stop it.
2. Ask the user with AskUserQuestion to type the secret into the pane at the prompt, press Enter, repeat it when asked, and answer "Done". The input is not echoed.
3. Read the pane with the next `tmux-relay send` of the flow. Success is exactly one line, `replaced N occurrence(s) in <config>`. Any other line is the error. Then `<exec> grep -c <placeholder> <config>` must print `0`. Never `cat` the file.

Use `--urlencode` when the placeholder sits inside a URL or DSN (`postgres://user:__DB_PASSWORD__@host/db`): characters such as `@`, `/` and `%` would otherwise break the string.

State files. Write whatever the reference's update flow reads later, in the format the helper that writes them uses; read that helper's body rather than assuming a format.

Service. Create the unit exactly as the reference does, then `systemctl enable --now <unit>`.

### 9. Verify

```bash
<exec> bash -c 'systemctl is-active <unit>; ss -ltnp | grep -E ":<port> "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<port>/; journalctl -u <unit> -n 30 --no-pager'
curl -s -o /dev/null -w "%{http_code}\n" http://<IP>:<port>/     # from the host
```

Expect the unit active, the port listening on all addresses, an HTTP answer, and log lines showing the database connected and migrations finished when the service has one. Report the address and port to the user; the reverse proxy, DNS and backups are outside this skill.

### 10. Clean up

Always, including after a failed or abandoned run:

1. If step 8 raised the resources, set them back to the values recorded there. A limit that was not set (no `cores:` line, or an empty Incus value) is removed again with `pct set <ID> --delete cores` or `incus config unset <name> limits.cpu`.
2. In the guest, remove `/root/set-secret.sh`, build sources, caches (`~/.cache`, `~/.npm`, `~/.cargo/registry` when the toolchain is not needed to run), logs of the transient units, and run `apt-get -y autoremove && apt-get clean`. Keep whatever the reference's update flow needs (its version file, a toolchain the update rebuilds with).
3. On the host, remove copy leftovers: `rm -f /tmp/set-secret.sh /tmp/set-secret.sh.b64`.
4. Proxmox: `pct fstrim <ID>`, because the pve/data thin pool never reclaims deleted blocks on its own.
5. If the install failed and the user wants to start over, `pct destroy <ID> --purge` or `incus delete -f <name>` only after they confirm.

## Copy a file into the guest

The pane is the only channel to the host, so files travel as base64 chunks. Run locally from the repository root:

```bash
f=set-secret.sh
tmux-relay send -w <win> -t <pane-id> "rm -f /tmp/$f.b64" </dev/null >/dev/null
base64 < .claude/skills/install-service/scripts/$f | tr -d '\n' | fold -w 2000 |
  while read -r chunk || [[ -n $chunk ]]; do
    tmux-relay send -w <win> -t <pane-id> "printf %s '$chunk' >> /tmp/$f.b64" </dev/null >/dev/null
  done
md5 -r .claude/skills/install-service/scripts/$f
```

Then on the host, decode, push into the guest, remove the host copies and verify:

```bash
base64 -d /tmp/set-secret.sh.b64 > /tmp/set-secret.sh && pct push <ID> /tmp/set-secret.sh /root/set-secret.sh --perms 0755 && rm -f /tmp/set-secret.sh /tmp/set-secret.sh.b64        # Proxmox
base64 -d /tmp/set-secret.sh.b64 > /tmp/set-secret.sh && incus file push --mode 0755 /tmp/set-secret.sh <name>/root/set-secret.sh && rm -f /tmp/set-secret.sh /tmp/set-secret.sh.b64   # Incus
<exec> bash -c 'md5sum /root/set-secret.sh; bash -n /root/set-secret.sh && echo syntax-ok'
```

The checksum in the guest must match the local one.
