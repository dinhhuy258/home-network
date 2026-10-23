# RF bridge for the LK-X002-3 ceiling fan

The LK-X002-3 (Zhongshan Eco Lighting Co., Ltd.) is a ceiling fan with a 433.92 MHz remote. An ESP32 with a CC1101 radio module runs ESPHome and sends the same radio frames as the remote. It also listens to the remote, so Home Assistant (HA) follows what the remote does. The fan sends nothing back, so the state in HA is the last command that was sent or heard.

Firmware: [`ceiling-fan.yaml`](ceiling-fan.yaml).

## 1. Hardware

- CC1101 module, green board with a 2×4 pin header
- ESP32 DevKit V1, 30 pins, CP2102 USB chip
- Jumper wires

### Wiring

The CC1101 header only prints the numbers 1, 2, 7 and 8 in the corners; one row holds the odd pins, the other row the even pins.
The ESP32 board prints the GPIO number with a D in front: GPIO26 is `D26`.

| CC1101 | ESP32 |
|---|---|
| 1 GND | GND |
| 2 VCC | **3V3** |
| 3 GDO0 (TX) | D26 |
| 4 CSN | D5 |
| 5 SCK | D18 |
| 6 MOSI | D23 |
| 7 MISO | D19 |
| 8 GDO2 (RX) | D27 |

The CC1101 takes 3.6 V at most, so VCC goes to `3V3`, never to `VIN`.

## 2. Flashing and logs

ESPHome runs on the Mac as a uv tool.

```bash
uv tool install esphome
cd esphome/ceiling-fan
esphome run ceiling-fan.yaml --device /dev/cu.usbserial-0001   # first flash over USB
esphome upload ceiling-fan.yaml --device 192.168.30.30         # later updates over the air, at the ESP32's IP
esphome logs ceiling-fan.yaml --device 192.168.30.30           # live log over the network
```

Copy [`secrets.example.yaml`](secrets.example.yaml) to `secrets.yaml` and fill it in; `secrets.yaml` is not committed.
The device name, the friendly name and the remote address are set once in `substitutions` at the top of the yaml.
The boot log shows the CC1101 chip as `0x0014` at 433.92 MHz, ASK/OOK, 9.9 dBm.
Every remote press shows up in the log as a line that starts with `RX`, with the remote address, the decoded command, the counter and the check result.
To pair the bridge with another remote of this model, press any button on it, read `addr=` from that line and put the value in `remote_address`.

When the ESP32 cannot join the saved WiFi for 90 seconds, it opens a hotspot named `f1-living-room-fan` with the `ap_password`.
A phone joined to that hotspot gets a page to pick a new WiFi.

## 3. Firmware behaviour

The firmware creates three entities: a fan with 6 speed levels and a direction, a Turbo button and a Counter number (diagnostic, editable by hand).
Level 1 to 6 shows up as 17, 33, 50, 67, 83 and 100 %.
Forward blows air down and turns counter-clockwise seen from below, reverse pulls air up and turns clockwise.

- The fan entity is a template fan with `speed_count: 6` and direction support.
- The counter, the last level and the direction are stored in flash, so they survive a reboot and an OTA update.
- The power state is not stored. After an ESP32 reboot or OTA update the entity shows off, even when the fan is running.
- When HA changes the entity, the `on_state` lambda compares the new state with the stored one and only sends what changed: the level code when the fan turns on or changes level, the Off code when it turns off, and the direction code when the direction changes.
- Frames go out through the queued script `send_fan_cmd`, which raises the counter, builds the 32-bit frame and sends it 5 times, then waits 300 ms so two commands never overlap on air.
- Every frame heard from the remote is decoded by the `on_raw` lambda. When the address and the check are right, the counter is copied from the remote, and the command is mirrored into the entity without sending anything back.

## 4. Radio protocol

- 433.92 MHz, ASK/OOK.
- Bit `0` = high 250 µs, low 750 µs. Bit `1` = high 750 µs, low 250 µs.
- A frame is 32 bits followed by one 250 µs high stop pulse. The remote sends about 4 identical frames per press, 41 ms apart, with an 8.7 ms gap between frames.
- Frame layout: 20-bit remote address `01110000011110101110` (`0x707AE`, the `remote_address` substitution) + 5-bit command + 3-bit counter + 4-bit check.
- The counter is shared by all buttons: +1 on every press, 7 wraps to 0. It does not have to continue from the remote's value: the ESP32 keeps its own counter and the fan accepts its frames.
- Check = high nibble XOR low nibble of the 8-bit value "command followed by counter" XOR `1110`.
- The firmware sends with the `rc_switch_raw` protocol: `pulse_length: 250`, `zero: [1, 3]`, `one: [3, 1]`, `sync: [1, 35]`.

Example: level 3 with counter 6 = `01110000011110101110` + `11100` + `110` + `0110`.

### Commands

| Remote button | Meaning | Command |
|---|---|---|
| 风速− / 风速+ | Level 1 to 6 | `10000` (16), `10010` (18), `11100` (28), `01010` (10), `01111` (15), `01100` (12) |
| 风扇开 | On, sends the level 3 code | `11100` (28) |
| 风扇关 | Off | `10110` (22) |
| 强劲风 | Turbo, a separate code, not level 6 | `11010` (26) |
| 一键反转 | Air down, HA forward | `00100` (4) |
| 一键反转 | Air up, HA reverse | `10001` (17) |

## Sources

- ESPHome CC1101: https://esphome.io/components/cc1101/
- CasaFan Eco Plano II example config: https://community.home-assistant.io/t/esphome-casafan-eco-plano-ii-ceiling-fan-rf-control/1023015
