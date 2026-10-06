---
name: upgrade-service
description: Upgrade a self-hosted service running natively in a Proxmox or Incus container, or on a plain VM. Use when the user asks to upgrade or update a self-hosted service.
argument-hint: <service>
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read, Write(.claude/skills/upgrade-service/*), Edit(.claude/skills/upgrade-service/*), AskUserQuestion, Skill
---

# Upgrade a native service

Read the reference for the requested service first and follow it together with this flow.

| Service | Reference | Host / guest | Scripts |
|---|---|---|---|
| Immich | `references/immich.md` | Proxmox LXC `immich`, plus the Oracle ML VM | `scripts/immich-compile.sh`, `scripts/immich-upgrade.sh` |
| Frigate | `references/frigate.md` | Proxmox LXC `frigate` on pve2, Docker Compose | none, all commands inline |
| Vaultwarden | `references/vaultwarden.md` | Proxmox LXC `vaultwarden` | none, all commands inline |
| Voice (Wyoming Whisper and Piper) | `references/voice.md` | Proxmox LXC `voice` on pve1 | none, all commands inline |

## Pick the reference

- The service is the skill argument. If it is missing, ask with AskUserQuestion.
- Look it up in the services table above.
- If there is no reference, tell the user and ask whether to upgrade it by hand now. Stop on no. On yes, ask for whatever they have on how the service was installed and is upgraded (a community-scripts installer such as `ct/<name>.sh` in community-scripts/ProxmoxVE, install notes, the project's upgrade docs) and read it. Then follow the flow; step 2 gathers the facts from the guest.

## Operating rules

- Every comment or description written to a server must be in English.
- Never print secrets from a `.env`, `config.json` or similar in the conversation.
- Never print a line that holds a secret, not even masked: a hand-written mask breaks when the secret contains its delimiter (an `@` inside a database password). Extract only the non-secret part (`${url##*@}` for the host and database, `${url#*://}` then `${x%%:*}` for the user) or test presence with `grep -c '^KEY=' <file>`.
- Stop the service once: install every new piece (binary, web assets, plugins) before the single `systemctl start`, unless the reference's script handles the restart itself.

## Runtimes

Services run in a Proxmox LXC or an Incus container; the reference says which. `<exec>` in the flow means "run inside the guest": `pct exec <ID> --` on Proxmox, `incus exec <name> --` on Incus.

## Flow

For each step, follow the reference's section of the same name when it has one. Without a reference, work the commands out from this flow, the facts gathered in the guest and the sources the user gave.

### 1. Select the pane

Invoke the `ssh-shell` skill and let the user select a pane SSH'd into the host that owns the container.

### 2. Find the host and the guest (read-only)

Check that the pane is on a host of the expected runtime, then look the guest up by name and confirm its service unit is installed. Without a reference, take the runtime, guest name and unit from the user's sources or ask.

```bash
hostname; command -v pct incus                      # exactly the runtime from the reference must be present
pct list | awk -v n=<name> '$NF == n {print $1}'    # Proxmox: prints the ID
<exec> systemctl cat <unit> >/dev/null && echo unit-ok
```

On Incus, `incus list '^<name>$' -c n --format csv` must print exactly that name; its name is the exec target. **Stop immediately and tell the user** if the runtime does not match, no guest matches, more than one matches, or the unit is missing. Do not guess an ID and do not try another pane on your own. Every `<ID>` in the reference means the ID resolved here.

Without a reference, also gather the facts read-only now: install paths, config files, installed version, database, resources.

### 3. Check what is needed (read-only)

Record the installed version and compare it against the latest upstream release, and against the pinned release if the reference has one. The reference lists the exact commands. Then read the release notes of every version in between for breaking changes (removed env vars, minimum Postgres version, required toolchain). **Stop and tell the user** if the installed version already equals the target release; there is nothing to upgrade. Also stop and report if the reference says its upstream source changed in a way the local procedure does not cover yet.

### 4. Offer a rollback point (user may decline)

The new version may run DB migrations on first start, so a container snapshot alone does not make a rollback clean. Offer a snapshot of the guest and a dump of the service's database, and let the user decline either.

Snapshot the guest:

```bash
pct snapshot <ID> pre_<service>_<TAG> --description "Before <service> <TAG> upgrade"   # Proxmox
incus snapshot create <name> pre_<service>_<TAG>                                       # Incus
```

The database lives in another guest. The reference names the engine and where the service keeps its connection details; read the host address and database name from there without printing the password. Find the guest that owns that address on the pane's host, check its free space (the dump can be large), then dump into the postgres user's home there:

```bash
grep -l "ip=<db-host>/" /etc/pve/lxc/*.conf                                    # the Proxmox guest holding the database
pct exec <PG-ID> -- df -h /var/lib/postgresql
pct exec <PG-ID> -- su - postgres -c "pg_dump -Fc <db> -f /var/lib/postgresql/<db>-pre-<TAG>.dump && ls -lh /var/lib/postgresql/<db>-pre-<TAG>.dump"
```

If the address does not match a guest on this host, the database is elsewhere. Stop and ask the user where to dump instead of guessing.

### 5. Upgrade

Follow the reference's upgrade section. If it lists build resources, record the current ones, then raise them:

```bash
pct config <ID> | grep -E '^(cores|memory):'                       # Proxmox: record before raising
incus config get <name> limits.cpu; incus config get <name> limits.memory   # Incus: record before raising
pct set <ID> --cores N --memory MB                                  # Proxmox
incus config set <name> limits.cpu=N limits.memory=<N>MiB          # Incus: the unit is required; a bare number is bytes
```

Run anything long (a compile, `npm install`, `uv sync`) as a transient systemd unit in the guest. A background job started through `<exec>` dies when the exec returns. The executable must be an absolute path, because `systemd-run` resolves it before applying `-E PATH`.

```bash
<exec> systemctl reset-failed <unit> 2>/dev/null    # a failed previous run blocks the unit name
# truncate: drops the previous run's log; append: sends stderr to the same file
<exec> systemd-run --unit=<unit> -E HOME=/root <more -E/-p from the reference> \
  -p StandardOutput=truncate:<log> -p StandardError=append:<log> \
  <absolute command>
```

Wait with this loop and nothing else. An empty read means the pane was busy, not that the unit finished, so only a non-empty value other than `active` ends the loop:

```bash
while :; do s=$(tmux-relay send -w <win> -t <pane-id> "<exec> systemctl is-active <unit>" </dev/null 2>/dev/null | tail -1 | tr -d '[:space:]'); [[ -z "$s" || "$s" == active ]] || break; sleep <poll>; done; echo "unit ended: $s"
```

Run the loop with the Bash tool's `run_in_background` option: a foreground Bash call is killed after at most 10 minutes and the builds take longer, while the background call keeps running and notifies you when it exits. Do not send anything else to that pane while the loop runs, or the two outputs interleave. The poll interval (`<poll>`, in seconds) and the expected duration are in the reference.

`inactive` means the unit finished; confirm success from the log as the reference describes. `failed` means read the log. Finish with the reference's verification commands and check every expected log line it lists.

### 6. Clean up

Always, including after a failed or abandoned run:

1. If step 5 raised the resources, set them back to the values recorded there. A limit that was not set (no `cores:` line, or an empty Incus value) is removed again with `pct set <ID> --delete cores` or `incus config unset <name> limits.cpu`.
2. In the guest, remove the build sources, logs and caches the reference lists. Keep whatever the reference says to keep.
3. Ask whether to keep the snapshot and the DB dump from step 4. Remove what the user does not want, the dump from the database guest.
4. Trim. Proxmox: `pct fstrim <ID>`, because the pve/data thin pool never reclaims deleted blocks on its own. Incus: only if the reference says so.

### 7. Save the reference (no reference only)

Ask the user whether to store the procedure in the skill. Stop here on no. On yes, write `references/<service>.md` from what actually worked, using an existing reference as the template: an environment facts table with the guest name, the service unit (never an ID) and where the database connection details live, a section named after each flow step it adds to (Check, Upgrade, Clean up) with the commands that worked, the poll interval and durations of the long steps, the log lines that confirmed success, and notes on deviations from the user's sources. Put any scripts in `scripts/` with a header that records the upstream source they mirror, and add one row to the services table above. Write every sentence on one line; do not hard-wrap paragraphs or bullets.
