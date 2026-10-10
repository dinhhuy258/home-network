---
name: home-assistant-naming
description: Naming rules for Home Assistant and Zigbee2MQTT (floors, areas, devices, entities, helpers, automations). Use when naming, renaming or reviewing anything in HA or Z2M, or when adding a device, helper, automation, script or scene.
---

# Home Assistant naming

## Entity ID format

HA is set to **Floor + Area + Device + Entity**. Every entity_id is built from names and areas, never typed by hand.

```
<domain>.<floor>_<area>_<device>_<entity>    entity without its own area
<domain>.<floor>_<area>_<entity>             entity with its own area (device part dropped)
```

After any name or area change, press **Recreate entity ID** in the entity settings. Then fix every automation, script, blueprint input and dashboard that used the old ID.

## Floors

`F1`, `F2`, `F3`. floor_id `f1`, `f2`, `f3`.

## Areas

- Short English name, capitalised first word only: `Living room`, `Master WC`, `Front yard`.
- No floor prefix. Names are unique in the house.
- Same room type on another floor: no word = F1, `Upper` = F2, `Top` = F3. Example: `Stairs`, `Upper stairs`, `Top stairs`.
- Area of a device = where the device is mounted. Area of a load entity = where the load is.

## Z2M devices (switches, sensors)

`friendly_name` in Z2M = device name in HA, identical.

```
f<floor>_<location>_<type>[_left|_right]
```

- Lowercase, underscores, English, no brand or model, no `_1`/`_2`.
- `location` = the spot where the plate or sensor is mounted (`entrance`, `stairs`, `master_bed`, `master_wc`, `living_room`). It often equals an area_id but does not have to: `f1_entrance_switch_left` sits in area Living room, `f2_master_wc_switch_left` in area Master.
- `type` = `switch`, `sensor`, `contact`. A multi-function sensor is just `sensor`.
- Two plates at one spot: `_left` / `_right` as seen by the person pressing.
- Examples: `f1_entrance_switch_left`, `f1_kitchen_switch`, `f2_master_wc_sensor`.

## Load entities (the gang wired to a load)

For each gang that drives a load:

1. Turn off "Use device area", set the area to where the load is.
2. Entity name = the load, no area in it: `Light`, `Track light`, `Cove LED`, `Fan`, `Water heater`.
3. Show as: `Light` for lights and LEDs, `Fan` for fans. Water heaters stay `switch`.
4. Recreate entity ID → `light.f1_living_room_track_light`.
5. Expose to Assist, add English aliases if useful.

Rules:
- One load = one entity. Only the gang holding the wire represents the load.
- Setting an own area without an own name causes a Repairs warning. Always do both.
- Presence sensors: entity name `Presence`, own area → `binary_sensor.f1_wc_presence`.

Example: `f1_entrance_switch_right`, a 2-gang plate by the front door, device area Living room.

| Gang | Wired to | Area | Entity name | Show as | entity_id |
|---|---|---|---|---|---|
| l1 | front yard light | Front yard | Light | Light | `light.f1_front_yard_light` |
| l2 | living room fan | Living room | Fan | Fan | `fan.f1_living_room_fan` |

The plate name never appears in a load's ID: the area comes from the load, the device part is dropped.

## Gangs without a load, auxiliary entities

- Decoupled gangs, second plates, `_battery`, `_illuminance`: keep the Z2M-suggested ID (`switch.f2_master_bed_switch_left`, `sensor.f1_wc_sensor_battery`), no own area, hidden, not exposed.
- Relay suffixes follow the Aqara endpoints: 3-gang `_left`, `_center`, `_right` for l1, l2, l3; 2-gang `_left`, `_right`; 1-gang no suffix (`switch.f2_lightwell_switch`). A plate already ending in `_left` gives `switch.f2_master_switch_left_left`, which is fine because the relay is hidden.
- Z2M 2.x creates no `sensor.*_action` entity. Presses reach HA only as MQTT device triggers or on the topic `zigbee2mqtt/<friendly_name>/action`, with payloads such as `single_left`, `single_right`.
- Set a decoupled gang with its `select.<device>_operation_mode_<endpoint>` = `decoupled`.
- Aqara decoupled gangs send Aqara multistate events, not OnOff commands, so a Zigbee bind cannot drive another plate. Two-way control is an HA automation, and the secondary gang does nothing while HA or Z2M is down.
- Automations trigger on the action and control the load by entity_id.

Example: `f2_master_bed_switch`, a 3-gang plate by the bed with no wires; the master lights are wired to `f2_master_switch_left`.

| Entity | Keep ID | Hidden | Exposed | Automation on `zigbee2mqtt/f2_master_bed_switch/action` |
|---|---|---|---|---|
| `switch.f2_master_bed_switch_left` | yes | yes | no | `single_left` → `light.toggle` `light.f2_master_light` |
| `switch.f2_master_bed_switch_center` | yes | yes | no | `single_center` → `light.toggle` `light.f2_master_bed_light` |
| `switch.f2_master_bed_switch_right` | yes | yes | no | `single_right` → `light.toggle` `light.f2_master_cove_led` |

Voice and dashboards see one `light.f2_master_light`, whichever plate switches it.

## Non-Z2M devices (VACA, browser_mod, Frigate…)

- Device name = type, capitalised: `Assistant`, `Display`, `Camera`, `Doorbell`.
- Area = where the device sits. Never two devices of one type in one area.
- Entities keep the device area (no own area), then Recreate → `camera.f1_front_yard_camera`, `switch.f1_living_room_assistant_screen`.
- System devices with no location (HA, add-ons, HACS, Sun, Frigate server, Immich, phones) keep their integration names.

## Helpers, automations, scripts, scenes

- Name = the job only, capitalised first word: `Night`, `Timer`, `Night mode`, `Assist overlay`.
- Belongs to a room: assign that area, then Recreate → `input_boolean.f1_living_room_night`, `automation.f1_living_room_night_mode`.
- House-wide: no area, self-explanatory name → `automation.away_mode`.
- HA builds the ID from the name alone at creation (`input_boolean.night`); the area only enters the ID on Recreate.

## Aliases and voice

- Aliases in English only, lowercase: `track light`, `kids water heater`.
- Do not expose: decoupled gangs, auxiliary entities, the Display's `light.*_display_screen` and `media_player.*_display`.

## Checklist for a new Z2M device

1. Pair, set `friendly_name` per the pattern.
2. HA: set the device area. New room → create the area, assign the floor.
3. Each load gang: own area + entity name + Show as + Recreate.
4. Check the ID is `<domain>.<floor>_<area>_<entity>`.
5. Expose + aliases.
6. Non-load gangs: hide, write the automation.
