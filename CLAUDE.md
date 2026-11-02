# Home network

This repo holds the firmware, the Tailscale policy and the Claude skills for a self-hosted home network and smart home in a 3-floor house.
Most tasks change a running system (Home Assistant, the router, a Proxmox guest, an Oracle container) through its UI, API or SSH, not the files in this repo.

## Network

- Router: MikroTik (RouterOS 7), the gateway, firewall, DHCP and DNS for every VLAN.
- Wi-Fi: Aruba Instant APs, one per floor, managed from the Virtual Controller.
- Hypervisors: Proxmox cluster pve1 + pve2. NAS: Synology, also the cluster QDevice.

| Device | Address |
|---|---|
| MikroTik router | `192.168.10.1` |
| Aruba Virtual Controller | `https://192.168.10.10:4343` |
| Proxmox pve1 | `https://192.168.10.21:8006` |
| Proxmox pve2 | `https://192.168.10.22:8006` |
| Synology NAS | `https://192.168.10.31:5001` |

## VLANs

The third octet equals the VLAN ID: `192.168.<vlan>.0/24`, gateway `.1`.
A higher number means less trust.

| VLAN | Name | Holds | Wi-Fi |
|---|---|---|---|
| 10 | MGMT | router, switches, APs, Proxmox hosts, NAS, the admin Mac | `BunnyBurrow`, MGMT passphrase |
| 15 | HOME | family phones, laptops, TV | `BunnyBurrow`, HOME passphrase |
| 20 | SERVER | all LXC and VM guests, static IPs only, no DHCP | — |
| 30 | IOT | Wi-Fi smart devices: robot vacuum, ESP32 bridges, Echo devices, cameras, doorbell | `BunnyBurrow-IoT` (2.4 GHz) |
| 40 | GUEST | untrusted devices, captive portal | `BunnyBurrow-Guest` |

`BunnyBurrow` is one SSID with MPSK: the passphrase a client uses decides whether it lands in MGMT or HOME.

- Cameras and the doorbell use `192.168.30.11`–`.15`; they are in the router address-list `CAMS` and have no internet.
- Firewall rules use address-lists, not VLANs alone.
- DNS: every client asks the router, the router forwards to AdGuard Home on VLAN 20.
- Remote access is Tailscale only, through the subnet router on pve1. The only ports open on the WAN are 80 and 443, forwarded to Caddy.

## Servers (VLAN 20)

- Services run as LXCs and VMs on pve1 and pve2, with static IPs on VLAN 20.
- The IP of a guest does not follow its LXC ID; never guess it, ask me or look it up on Proxmox.
- pve1 is powered off every night from 00:00 to 06:30. Services on pve1 are down in that window.

## Oracle cloud host

- Oracle "incus" host (arm64, Incus), only 443 open, containers on `10.250.0.0/24`.
- Run commands in a container with `incus exec <name> -- ...`; use `systemd-run` for long jobs.

## Home Assistant

- URL: `https://home.dinhhuy258.dev` or `http://192.168.20.7:8123`.
- Work with HA through the `home-assistant` MCP server (ha-mcp). Load its best-practices skill first, as the server asks.
- Zigbee: Zigbee2MQTT add-on + Mosquitto on HA, channel 11 (never change it).
- Cameras: Frigate with go2rtc; HA talks to it over MQTT.
- Voice: Kiosk Satellite on the Echo devices; the Assist pipelines use the own integration `hermes_assist` (Hermes conversation agent).
- Other own integration: `philips_lock` (front door lock, unlock only).
- Naming: Z2M `friendly_name` is `f<floor>_<room>_<type>` and equals the HA device name. Follow the `home-assistant-naming` skill for all names.
- Dashboards: Mushroom is the only HACS card allowed. For any change to an HA dashboard, show a mockup first, then edit the live config after my OK.
- Never edit `.storage` files directly; use the UI, the API or the MCP tools.

## How to reach hosts

- Router: `ssh dinhhuy258@192.168.10.1` (RouterOS CLI) or Winbox.
- Proxmox: `tailscale ssh root@proxmox` (pve1), then `ssh pve2` from pve1.
- Aruba: SSH offers only `ssh-rsa`, so the client needs `HostKeyAlgorithms +ssh-rsa`. Slave APs have no own web UI; edit them from the VC under Configuration → Access Points.
- I usually keep SSH sessions open in tmux panes.

## How to work here

- Never change a file, host or device without an explicit "go ahead" from me.
- Ask before opening SSH to any host or typing into my tmux panes.
- When I run commands on a router or device myself, give one command or check per message.
- Before any rename in HA or Z2M, show the old → new mapping and the target device, then wait for my OK.
- Install and upgrade services with the `install-service` and `upgrade-service` skills; mirror the reference script I name.
- Ask for a token or API key only at the step that uses it, not up front.
- Use `duongdinhhuy1993@gmail.com` for ACME and other external sign-ups.
- Take what I state about my accounts and setup at face value; do not read my credentials or usage data to check it.

## Secrets

- Never print a line that holds a secret, not even masked. Extract only the part you need (for example `${url##*@}`).
- Never grep a secrets file: on this Mac `grep` is wrapped by RTK and prints the matching lines even with `-c`. Count with `awk` instead.
- Frigate: allow-list keys when printing `/api/config/raw`; go2rtc log lines and camera `onvif` blocks hold plain-text passwords.

## Writing style

- Every comment in a config, script or RouterOS object is professional English.
- Docs describe only the current, verified setup: no changelogs, no comparisons with old designs, nothing planned.
- Plain, simple English. Facts only.
- Markdown: one sentence or bullet per source line, no hard wrapping.
- Committed skills must not link to uncommitted files.
