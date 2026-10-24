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
- `type` = `switch`, `sensor`, `contact`, `curtain`. A multi-function sensor is just `sensor`.
- Two plates at one spot: `_left` / `_right` as seen by the person pressing.
- Two curtain motors on one window: the layer as suffix, `_blackout` / `_sheer`.
- Examples: `f1_entrance_switch_left`, `f1_kitchen_switch`, `f2_master_wc_sensor`, `f2_master_curtain_blackout`.

## Button order on a plate

Left and right are as seen by the person pressing.

1. Default: the most-used load goes on the leftmost button, the same side on every plate, so `l1` is usually the main light of the area.
2. Proximity overrides the default: when a load serves a spot right next to the plate (a staircase, a doorway), its button is the one nearest that spot, even if that is not `l1`.
3. Keep loads of the same kind together; the odd one out (a fan, an outdoor light) goes at the far end.
4. Two plates side by side: the plate for the zone physically on the left is the left plate.

Examples of rule 2:
- `f2_stairs_up_switch` sits at the foot of a flight with the stairs on its left: `l1` = stairs light, then the family and hallway lights.
- `f2_master_wc_switch_right` sits beside the WC door on its right: the WC light is `l2` (right), the button nearest the way in and out; the exhaust fan is `l1`.

## Load entities (the gang wired to a load)

For each gang that drives a load:

1. Turn off "Use device area", set the area to where the load is.
2. Entity name = the load, no area in it: `Light`, `Track light`, `Cove LED`, `Fan`, `Water heater`.
3. Show as: `Light` for lights and LEDs, `Fan` for fans, `Curtain` for curtains. Water heaters stay `switch`.
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
- Roaming devices (robot vacuum) get no area: device name = type, specific enough to stay unique → `Robot vacuum`, `Robot dock` → `vacuum.robot_vacuum`, `switch.robot_dock_mop_washing`.
- System devices with no location (HA, add-ons, HACS, Sun, Frigate server, Immich, phones) keep their integration names.

## Helpers, scenes

- Name = the job only, capitalised first word: `Lights`, `Curtains`, `Lights on`, `Camera recording`.
- Belongs to a room: assign that area, then Recreate → `light.f1_front_yard_lights`, `light.f3_balcony_lights`, `cover.f2_master_curtains`.
- A group of loads in one area is named after the loads in the plural: `Lights`, `Curtains`.
- Belongs to a floor: no area, the floor goes first in the name → `F1 lights on` → `sensor.f1_lights_on`.
- House-wide: no area, self-explanatory name → `sensor.lights_on`, `light.outdoor`, `input_text.camera_recording`.
- HA builds the ID from the name alone at creation (`light.lights`); the area only enters the ID on Recreate.
- Scenes follow the same rules.

## Automations, scripts

- The automation list is flat and shows names only, so the name carries the location (or the system it serves) plus the job: `WC presence light`, `Master WC presence light`, `Living room VACA night mode`, `Stairs light from F2 stairs switch`.
- Location = the area of the load or room the automation serves, in the short area form (`WC`, `Master WC`, `Living room`). A VACA satellite automation is named after its room plus `VACA`.
- A decoupled-gang automation is `<load> from <plate>`: `Master light from bed switch`, `Family light from stairs up switch`.
- Still assign the room area, but do not Recreate: the entity_id stays `automation.f1_wc_presence_light` even when the name is `WC presence light`.
- House-wide: no area, job name alone → `Camera recording timeout`.
- English description on every automation, saying what it does and why.

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
