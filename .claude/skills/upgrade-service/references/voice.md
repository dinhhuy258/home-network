# Voice (Wyoming Whisper and Piper)

Two Wyoming servers installed from PyPI into their own Python venvs; there is no build, so the upgrade is a `pip install -U` per venv between a stop and a start of its unit.

## Environment facts

| Item | Value |
|---|---|
| Guest | Proxmox LXC `voice` on pve1 (Debian 13, system Python 3.13) |
| Speech-to-text | Unit `wyoming-whisper`, venv `/opt/wyoming-whisper/.venv`, package `wyoming-faster-whisper[sherpa]` (upstream OHF-Voice/wyoming-faster-whisper), port 10300 |
| Text-to-speech | Unit `wyoming-piper`, venv `/opt/wyoming-piper/.venv`, package `wyoming-piper` (upstream OHF-Voice/wyoming-piper), port 10200 |
| Models | `/opt/wyoming-whisper/data` and `/opt/wyoming-piper/data`; kept across upgrades |
| Model choice | Whisper runs `--model auto --language en`, which picks sherpa-onnx Parakeet TDT 0.6B v2 int8; without `--language en` auto falls back to faster-whisper base-int8. Piper runs voice `en_US-lessac-medium` with `--update-voices` |
| Database | None; no secrets in the guest |
| Consumer | Home Assistant Wyoming integrations `stt.faster_whisper_2` and `tts.piper_2`, used by the Assist pipeline "Hermes" |

Keep the `[sherpa]` extra on every Whisper install: without it the Parakeet model cannot load. Do not add `transformers`, `onnx_asr` or other extras; they are not used.

## Check

```bash
pct exec <ID> -- bash -c '/opt/wyoming-whisper/.venv/bin/pip show wyoming-faster-whisper sherpa-onnx | grep -E "^(Name|Version)"; /opt/wyoming-piper/.venv/bin/pip show wyoming-piper piper-tts | grep -E "^(Name|Version)"; python3 --version'
```

Locally:

```bash
for p in wyoming-faster-whisper wyoming-piper; do curl -s https://pypi.org/pypi/$p/json | python3 -c 'import json,sys; d=json.load(sys.stdin)["info"]; print(d["name"], d["version"], d["requires_python"])'; done
gh release list -R OHF-Voice/wyoming-faster-whisper -L 5
gh release list -R OHF-Voice/wyoming-piper -L 5
gh api repos/OHF-Voice/wyoming-faster-whisper/contents/CHANGELOG.md -H "Accept: application/vnd.github.raw" | head -40
gh api repos/OHF-Voice/wyoming-piper/contents/CHANGELOG.md -H "Accept: application/vnd.github.raw" | head -40
```

The two services are upgraded independently; stop only for the one already on the latest version. In the changelogs look for renamed or removed command-line flags (compare with `ExecStart` from `systemctl cat`), a changed `--model auto` pick for English, and a raised `requires_python` above the guest's Python.

## Rollback point

Record the installed versions from Check. The rollback is a reinstall of the old version into the same venv, for example `pip install --no-cache-dir 'wyoming-faster-whisper[sherpa]==3.8.1'` or `pip install --no-cache-dir 'wyoming-piper==2.5.2'`, then a start of the unit. A `pct snapshot` is optional; there is no database to dump.

## Upgrade

Run each upgrade as a transient unit, because the download can outlast the pane timeout. Whisper:

```bash
pct exec <ID> -- systemctl reset-failed voice-upgrade 2>/dev/null
pct exec <ID> -- systemd-run --unit=voice-upgrade -E HOME=/root -p StandardOutput=truncate:/root/voice-upgrade.log -p StandardError=append:/root/voice-upgrade.log /bin/bash -c 'set -e; systemctl stop wyoming-whisper; /opt/wyoming-whisper/.venv/bin/pip install --no-cache-dir -U pip setuptools wheel; /opt/wyoming-whisper/.venv/bin/pip install --no-cache-dir -U "wyoming-faster-whisper[sherpa]"; systemctl start wyoming-whisper; echo UPGRADE-DONE'
```

Piper is the same with `wyoming-piper`, `/opt/wyoming-piper/.venv` and the unit `wyoming-piper`. Poll every 15 s; each takes one to two minutes. If the unit fails, the service stays stopped: read the log, then reinstall the old version from Rollback point and start the unit.

Verify:

```bash
pct exec <ID> -- bash -c 'grep -E "UPGRADE-DONE|Successfully installed|ERROR" /root/voice-upgrade.log | cut -c1-200; sleep 20; systemctl is-active wyoming-whisper wyoming-piper; ss -ltn | grep -E ":(10300|10200) "; journalctl -u wyoming-whisper -u wyoming-piper -n 20 --no-pager | grep -viE "^-- " | cut -c1-200'
```

Expect both units `active`, both ports listening on `0.0.0.0`, and in the Whisper log the Parakeet model loading (not `base-int8`). Then run a round trip from the Mac: Piper synthesizes a sentence and Whisper transcribes it back over raw Wyoming. The test script is `wyoming_roundtrip.py`; if it is no longer in the scratchpad, rewrite it (send `synthesize` to port 10200 and collect `audio-chunk` until `audio-stop`, then send `transcribe`, `audio-start`, the chunks and `audio-stop` to port 10300 and read `transcript`):

```bash
python3 -I <scratchpad>/wyoming_roundtrip.py "Turn on the living room light."
```

Expect the sentence back verbatim, with STT around 1.5 s. In Home Assistant, `stt.faster_whisper_2` and `tts.piper_2` must not be `unavailable`; the Wyoming integration reconnects on its own after the restart.

## Clean up

```bash
pct exec <ID> -- bash -c 'rm -f /root/voice-upgrade.log; rm -rf /root/.cache/pip; df -h / | tail -1'
pct fstrim <ID>
```

Keep both `data` directories: they hold the downloaded models.
