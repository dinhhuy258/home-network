---
name: renumber-lxc
description: Change a Proxmox LXC's ID (e.g. 309 → 303) in place on pve1/pve2 without copying data — stop, lvrename the disks, move the config, start. Use when the user asks to rename/renumber/reorder an LXC ID or fill a gap left by a destroyed container.
argument-hint: <old-id> <new-id>
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash(tmux-relay:*), AskUserQuestion, Skill
---

# Renumber an LXC

Proxmox has no "change ID" command. On LVM-thin (`local-lvm`) the ID lives in only two places: the logical volume names (`vm-<id>-disk-N`) and the config file name (`/etc/pve/lxc/<id>.conf`). Renaming both is instant and leaves the data untouched. Do not fall back to vzdump/restore.

Invoke the `ssh-shell` skill first and let the user select a pane SSH'd into the node that owns the container.

## What survives / what is lost

- Kept: disk data, IP, MAC, `onboot`, `startup: order=`, tags, description, features. Nothing inside the guest refers to its own ID.
- Lost: the RRD graph history in the web UI (keyed by ID).
- Old vzdump archives keep the old ID in their name and will never be pruned by the new ID's retention. Step 4 handles them.

## 0. Preconditions

`OLD` and `NEW` are the skill arguments.

```bash
hostname; command -v pct
OLD=309 NEW=303
pct list | awk -v id=$OLD '$1 == id'                       # must print one line: the container is on this node
grep -E "\"$NEW\"" /etc/pve/.vmlist                        # must be empty: ID free cluster-wide
lvs --noheadings -o lv_name pve | grep -E "vm-$NEW-"       # must be empty: no orphan LV under the new ID
```

**Stop immediately and report** if `pct` is missing (wrong host), the container is not listed on this node, the new ID appears in `.vmlist` (say which node the entry names) or an LV with the new ID exists. Do not retry on another pane and do not pick another ID on your own.

## 1. Inspect (read-only)

```bash
pct status $OLD; cat /etc/pve/lxc/$OLD.conf
grep -E '^\[' /etc/pve/lxc/$OLD.conf                       # snapshot sections → stop, see below
lvs --noheadings -o lv_name,lv_size pve | grep -E "vm-$OLD-"
grep -rnwE "$OLD" /etc/pve/jobs.cfg /etc/pve/vzdump.cron /etc/pve/replication.cfg \
  /etc/pve/ha /etc/pve/user.cfg /etc/cron* /root/*.sh 2>/dev/null
ls /etc/pve/firewall/ | grep -w "$OLD"
pvesm list synology | grep "lxc-$OLD-"
```

Stop and ask the user if:
- the config has `[snapshot]` sections — delete the snapshots first (`pct delsnapshot`); snapshot LVs are named after the ID too;
- a disk is not on `local-lvm` (directory/NFS storage = rename the file `.../images/<id>/vm-<id>-disk-N.raw` and the `images/<id>` dir instead of `lvrename`).

References found in jobs.cfg (`vmid` lists), HA, replication, pools (`user.cfg`), cron, `/root` scripts or a `<id>.fw` firewall file must be moved to the new ID in the same pass (pool/HA: remove + re-add via `pvesh`/`ha-manager`; firewall: `cat $OLD.fw > $NEW.fw && rm $OLD.fw`).

## 2. Renumber

One `lvrename` per disk: the rootfs and every `mpN` on `local-lvm`. The chain below renames `disk-0` only; add one `lvrename` line per LV that step 1 listed before sending it. Then the config: **pmxcfs rejects `sed -i`**, so write the edited copy to the new file name and delete the old one.

```bash
pct stop $OLD \
 && lvrename pve vm-$OLD-disk-0 vm-$NEW-disk-0 \
 && sed "s/vm-$OLD-disk-/vm-$NEW-disk-/g" /etc/pve/lxc/$OLD.conf > /etc/pve/lxc/$NEW.conf \
 && rm /etc/pve/lxc/$OLD.conf \
 && pct start $NEW && sleep 5 && pct status $NEW && grep -E '^(rootfs|mp)' /etc/pve/lxc/$NEW.conf
```

Send the chain as one command with `--timeout 120`; do not split it. The `&&` chain stops at the first failure. If it does, check which step ran (`lvs`, `ls /etc/pve/lxc/`) before doing anything else.

## 3. Verify

- `pct list` shows `$NEW` running and no `$OLD`.
- The service inside is active and its port listens (`pct exec $NEW -- ss -ltnp`).
- The public URL through Caddy answers (Caddy proxies by IP, so nothing changes there).

Some services fail for a minute or two after a hard stop. Wait before debugging. Example: Pocket ID returns 502 with `already one instance of Pocket ID running` until its Postgres lease expires.

## 4. Clean up

- Re-run the step 1 `grep -rnwE "$OLD"`. Anything still matching is edited now.
- Old vzdump archives (`pvesm list synology | grep "lxc-$OLD-"`) stay until a backup under `$NEW` exists. Tell the user to delete them by hand after the next successful backup job, or do it now if they confirm they do not need a restore point from before the renumber.
