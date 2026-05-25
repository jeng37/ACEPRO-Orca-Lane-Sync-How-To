# ACEPRO / Rinkhals / OrcaSlicer LaneSync with SKU + Spool ID Matching

This README documents the complete working setup for syncing ACEPRO / Rinkhals lane data into OrcaSlicer so that Orca selects the **correct custom filament preset** by `sku` / `spool_id`, instead of falling back to generic material presets such as `Generic PETG` or `Generic PLA`.

The final goal is:

```text
ACE / RFID / Spoolman
        ↓
ACEPRO / Rinkhals inventory
        ↓
Klipper saved_variables.cfg
        ↓
ACEPRO moonraker_lane_sync.py
        ↓
Moonraker database namespace lane_data
        ↓
Patched OrcaSlicer Moonraker printer agent
        ↓
Orca Filament / AMS Sync
        ↓
Correct Orca user filament presets selected
```

Example final result in Orca:

```text
A1 -> Sunlu - White - 15
A2 -> Sunlu - Black - 11
A3 -> Sunlu - Orange - 19
A4 -> Sunlu - Carbon Fiber - 18
B1 -> Sunlu - Gold - 2
B2 -> Redline - Silky PLA - 17
B3 -> Sunlu - Blue - 20
B4 -> Polymaker - Transparent - 21
```

---

## 1. Tested setup

This README was created from a working setup using:

```text
Printer: Anycubic Kobra S1 Combo / KS1C style setup
ACE: ACE Pro, dual ACE also possible
Firmware environment: Rinkhals / Klipper / Moonraker
Host: Raspberry Pi running Moonraker + Mainsail / Fluidd
OrcaSlicer: 2.4.0-dev / 2.4.0-alpha based build
Base Orca patch: PR #13719 Moonraker vendor matching
Additional Orca patch: ACEPRO SKU / spool_id LaneSync matching
Additional ACEPRO patch: non-numeric SKU -> Spoolman spool_id via sku_map
```

The exact printer model name is not important. The important requirements are:

```text
1. ACEPRO writes lane data into Moonraker namespace lane_data.
2. lane_data contains material, color, vendor, sku and/or spool_id.
3. OrcaSlicer is patched to match these fields to user preset names.
4. Orca user filament presets have unique names containing vendor and spool ID.
```

---

## 2. ACEPRO LaneSync overview

ACEPRO publishes ACE lane information into Moonraker using the database namespace:

```text
lane_data
```

Verify from the Moonraker host:

```bash
curl -s "http://192.168.x.x:7125/server/database/item?namespace=lane_data" | jq
```

A good result looks like this:

```json
{
  "result": {
    "namespace": "lane_data",
    "key": null,
    "value": {
      "lane1": {
        "lane": "0",
        "material": "PETG",
        "color": "#FFFFFF",
        "vendor": "Sunlu",
        "sku": "15",
        "spool_id": 15,
        "nozzle_temp": 205,
        "bed_temp": 60
      },
      "lane2": {
        "lane": "1",
        "material": "PETG",
        "color": "#010101",
        "vendor": "Sunlu",
        "sku": "11",
        "spool_id": 11
      }
    }
  }
}
```

Important fields:

```text
material    PETG / PLA / PLA+ / etc.
color       #RRGGBB
vendor      Sunlu / Redline / Polymaker / etc.
sku         RFID SKU or mapped spool value
spool_id    numeric Spoolman spool ID
```

---

## 3. Enable LaneSync in ACE config

In the ACE config, Moonraker LaneSync must be enabled.

Example `ace.cfg` section:

```ini
moonraker_lane_sync_enabled: True
moonraker_lane_sync_url: http://127.0.0.1:7125
moonraker_lane_sync_namespace: lane_data
# moonraker_lane_sync_api_key: optional
moonraker_lane_sync_timeout: 2.0
moonraker_lane_sync_unknown_material_mode: empty
moonraker_lane_sync_unknown_material_markers: ???,unknown,n/a,none
moonraker_lane_sync_unknown_material_map_to: PLA
```

Restart Klipper / ACEPRO afterwards:

```bash
sudo systemctl restart klipper
```

Verify:

```bash
curl -s "http://192.168.x.x:7125/server/database/item?namespace=lane_data" \
| jq '.result.value | to_entries[] | {lane: .key, material: .value.material, vendor: .value.vendor, sku: .value.sku, spool_id: .value.spool_id}'
```

Expected:

```text
lane1 Sunlu PETG sku 15 spool_id 15
lane2 Sunlu PETG sku 11 spool_id 11
lane3 Sunlu PETG sku 19 spool_id 19
...
```

If this does not show data, fix ACEPRO / Moonraker LaneSync before working on Orca.

---

# 4. ACEPRO patch: non-numeric SKU -> Spoolman spool_id

## 4.1 Problem

Some ACE RFID tags provide non-numeric SKUs, for example:

```text
AHPEVO-102
AHPLBK-101
```

Orca and Spoolman matching works best when each lane has a numeric `spool_id`.

If ACEPRO only publishes this:

```json
{
  "vendor": "AC",
  "sku": "AHPEVO-102"
}
```

then `spool_id` may be missing.

## 4.2 Solution

Patch ACEPRO's `moonraker_lane_sync.py` so `_extract_spool_id()` resolves spool IDs in this order:

```text
1. If lane inventory already contains spool_id, use it.
2. Else if sku is numeric, use sku as spool_id.
3. Else if sku is non-numeric, look it up in saved_variables.cfg sku_map.
4. Else return None.
```

Example `saved_variables.cfg`:

```ini
[Variables]
sku_map = {'AHPEVO-102': 19, 'AHPLBK-101': 2}
```

This maps:

```text
AHPEVO-102 -> 19
AHPLBK-101 -> 2
```

## 4.3 ACEPRO patch script

Use the separate ACEPRO patch script:

```text
patch_acepro_lanesync_sku_map.sh
```

It patches:

```text
~/ACEPRO/extras/ace/moonraker_lane_sync.py
```

The patch adds:

```text
_load_sku_map()
_extract_spool_id()
```

The patched `_extract_spool_id()` supports:

```text
spool_id
spoolId
spool
numeric sku
non-numeric sku via sku_map
```

Default `sku_map` lookup paths include:

```text
/home/pi/printer_data/config/saved_variables.cfg
/home/pi/klipper_config/saved_variables.cfg
/home/pi/printer_data/config/variables.cfg
/useremain/home/rinkhals/printer_data/config/saved_variables.cfg
/useremain/home/rinkhals/printer_data/saved_variables.cfg
```

You can override the path with:

```bash
export ACEPRO_SKU_MAP_FILE=/home/pi/printer_data/config/saved_variables.cfg
```

## 4.4 Apply the ACEPRO patch

From the ACEPRO repo root:

```bash
cd ~/ACEPRO
chmod +x patch_acepro_lanesync_sku_map.sh
./patch_acepro_lanesync_sku_map.sh
```

Or directly inside `extras/ace`:

```bash
cd ~/ACEPRO/extras/ace
chmod +x patch_acepro_lanesync_sku_map.sh
./patch_acepro_lanesync_sku_map.sh ./moonraker_lane_sync.py
```

The script creates a backup like:

```text
moonraker_lane_sync.py.bak.sku_map_YYYYMMDD_HHMMSS
```

Then restart Klipper:

```bash
sudo systemctl restart klipper
```

## 4.5 Test the ACEPRO patch

From the ACEPRO repo root:

```bash
cd ~/ACEPRO

python3 - <<'PY'
from extras.ace.moonraker_lane_sync import MoonrakerLaneSyncAdapter

for sku in ["15", "AHPEVO-102", "AHPLBK-101", "NICHT_GEMAPPT"]:
    print(sku, "->", MoonrakerLaneSyncAdapter._extract_spool_id({"sku": sku}))
PY
```

Expected:

```text
15 -> 15
AHPEVO-102 -> 19
AHPLBK-101 -> 2
NICHT_GEMAPPT -> None
```

Then verify Moonraker lane data:

```bash
curl -s "http://192.168.x.x:7125/server/database/item?namespace=lane_data" \
| jq '.result.value | to_entries[] | {lane: .key, sku: .value.sku, spool_id: .value.spool_id}'
```

Expected:

```text
{
  "lane": "lane3",
  "sku": "AHPEVO-102",
  "spool_id": 19
}
```

or, after ACE inventory uses numeric mapped values:

```text
{
  "lane": "lane3",
  "sku": "19",
  "spool_id": 19
}
```

---

# 5. OrcaSlicer limitation

OrcaSlicer does not have full generic MMU sync support for custom Moonraker lane data.

Without patching, Orca often syncs only material and color:

```text
A1 PETG -> Generic PETG / Anycubic PETG
A2 PETG -> Generic PETG / Anycubic PETG
A3 PETG -> Generic PETG / Anycubic PETG
B1 PLA+ -> Generic PLA / SUNLU PLA+
```

What we need:

```text
A1 sku 15 -> Sunlu - White - 15
A2 sku 11 -> Sunlu - Black - 11
A3 sku 19 -> Sunlu - Orange - 19
B1 sku 2  -> Sunlu - Gold - 2
```

This requires an Orca source patch.

---

# 6. Orca filament preset requirements

Create or copy user filament presets whose names contain vendor and spool ID / SKU.

Example files:

```text
~/.config/OrcaSlicer/user/default/filament/Sunlu - White - 15.json
~/.config/OrcaSlicer/user/default/filament/Sunlu - Black - 11.json
~/.config/OrcaSlicer/user/default/filament/Sunlu - Orange - 19.json
~/.config/OrcaSlicer/user/default/filament/Sunlu - Gold - 2.json
~/.config/OrcaSlicer/user/default/filament/Redline - Silky PLA - 17.json
~/.config/OrcaSlicer/user/default/filament/Sunlu - Blue - 20.json
~/.config/OrcaSlicer/user/default/filament/Polymaker - Transparent - 21.json
```

The JSON internal `name` must match the filename without `.json`:

```json
{
  "name": "Sunlu - White - 15",
  "inherits": "Anycubic Generic PETG",
  "filament_type": ["PETG"],
  "compatible_printers": [],
  "compatible_printers_condition": ""
}
```

Important:

```text
Do not rely on Orca's internal filament_id for user presets.
Many different user presets can share internal IDs like GFG99 or GFL99.
The final patch therefore matches by preset name.
```

Repair user filament JSON names if needed:

```bash
cd ~/.config/OrcaSlicer/user/default/filament

python3 - <<'PY'
import json
from pathlib import Path

for path in Path(".").glob("*.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    data["name"] = path.stem
    data.pop("filament_id", None)
    data["compatible_printers"] = []
    data["compatible_printers_condition"] = ""
    data["compatible_prints"] = []
    data["compatible_prints_condition"] = ""
    path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
    print("fixed", path.name)
PY
```

Neutralize `.info` files if Orca keeps old base IDs:

```bash
cd ~/.config/OrcaSlicer/user/default/filament

python3 - <<'PY'
from pathlib import Path
import time

for info in Path(".").glob("*.info"):
    content = "\n".join([
        "sync_info = create",
        "user_id = ",
        "setting_id = ",
        "base_id = ",
        f"updated_time = {int(time.time())}",
        ""
    ])
    info.write_text(content, encoding="utf-8")
    print("fixed", info.name)
PY
```

---

# 7. OrcaSlicer patch overview

The working Orca patch has three required parts.

---

## 7.1 Moonraker lane matcher

File:

```text
src/slic3r/Utils/MoonrakerPrinterAgent.cpp
```

Function:

```cpp
MoonrakerPrinterAgent::fetch_moonraker_filament_data(...)
```

The patch reads lane fields:

```text
vendor
manufacturer
brand
sku
spool_id
filament_settings_id
filament_id
name
filament_name
material
```

It matches them to Orca user presets by:

```text
1. exact filament_settings_id / filament_id / name / filament_name
2. vendor + sku/spool_id in Orca preset name
3. sku/spool_id in Orca preset name
4. vendor + material fallback
```

Critical behavior:

```text
Return preset.name, not preset.filament_id.
```

Reason:

```text
User presets may share internal Orca IDs like GFG99/GFL99.
The visible preset name is unique and contains the spool ID.
```

Expected log:

```text
ACEPRO LaneSync FINAL: vendor='Sunlu' material='PETG' sku='15' spool_id='15' -> tray_info_idx='Sunlu - White - 15'
```

---

## 7.2 Expose tray_info_idx as filament_id

File:

```text
src/slic3r/Utils/MoonrakerPrinterAgent.cpp
```

Function:

```cpp
MoonrakerPrinterAgent::build_ams_payload(...)
```

The patch adds:

```cpp
tray_json["tray_info_idx"] = tray->tray_info_idx;
tray_json["filament_id"] = tray->tray_info_idx;
```

For empty slots:

```cpp
tray_json["tray_info_idx"] = "";
tray_json["filament_id"] = "";
```

Reason:

```text
Some Orca sync paths read filament_id instead of tray_info_idx.
Without this, the correct preset name reaches part of Orca but is not used by sync_ams_list().
```

---

## 7.3 Allow exact preset-name matches in sync_ams_list()

File:

```text
src/libslic3r/PresetBundle.cpp
```

Function:

```cpp
PresetBundle::sync_ams_list(...)
```

Vanilla logic can reject user presets because of strict checks like:

```cpp
f.is_compatible && filaments.get_preset_base(f) == &f && f.filament_id == filament_id
```

The working patch allows exact name matches without the compatibility/base restriction:

```cpp
return f.filament_id == filament_id || f.name == filament_id;
```

This fixes the log error:

```text
sync_ams_list: filament_id Sunlu - White - 15 not found or system or compatible
```

After the fix, Orca accepts:

```text
filament_id = "Sunlu - White - 15"
f.name      = "Sunlu - White - 15"
```

---

# 8. Build Orca with the all-in-one script

Use:

```text
orca_acepro_lanesync_all_in_one_build.sh
```

Run:

```bash
cd ~
chmod +x orca_acepro_lanesync_all_in_one_build.sh
./orca_acepro_lanesync_all_in_one_build.sh
```

Optional with manual job count:

```bash
JOBS=8 ./orca_acepro_lanesync_all_in_one_build.sh
```

Patch only, no build:

```bash
DO_BUILD=0 ./orca_acepro_lanesync_all_in_one_build.sh
```

Repair user filament profiles too:

```bash
FIX_USER_FILAMENTS=1 ./orca_acepro_lanesync_all_in_one_build.sh
```

The script does:

```text
1. backs up existing ~/OrcaSlicer if present
2. clones OrcaSlicer
3. fetches PR #13719
4. applies the ACEPRO / SKU / spool_id Orca patch
5. exports a patch file
6. builds an AppImage
7. copies the final AppImage to the home directory
```

Expected output:

```text
~/OrcaSlicer-ACEPRO-LaneSync-FINAL-working.AppImage
~/orca_acepro_lanesync_sku_spoolid_all_in_one.patch
```

---

# 9. Starting the patched AppImage

AppImageLauncher can interfere. Starting extracted is recommended:

```bash
cd /tmp
rm -rf orca-ace-run
mkdir orca-ace-run
cd orca-ace-run

~/OrcaSlicer-ACEPRO-LaneSync-FINAL-working.AppImage --appimage-extract >/dev/null
QT_QPA_PLATFORM=xcb ./squashfs-root/AppRun
```

Alternative filename:

```bash
~/OrcaSlicer-ACEPRO-PR13719-SKU-SpoolID.AppImage --appimage-extract >/dev/null
QT_QPA_PLATFORM=xcb ./squashfs-root/AppRun
```

---

# 10. Orca printer profile configuration

The Orca printer profile must have a physical printer connection that activates the patched Moonraker printer agent.

Working machine profile files are stored in:

```text
~/.config/OrcaSlicer/user/default/machine/
```

Example:

```text
~/.config/OrcaSlicer/user/default/machine/KS1C.json
```

Important fields:

```text
print_host
print_host_webui
printer_agent
host_type
printhost_apikey
printhost_cafile
```

If the Device tab loads but the Filament Sync button is missing, the web UI may be connected but the agent may not be active.

A newly created profile can be fixed by copying connection fields from a known working profile:

```bash
cd ~/.config/OrcaSlicer/user/default/machine

python3 - <<'PY'
import json
from pathlib import Path
from datetime import datetime
import shutil

src = Path("Anycubic Kobra S1 0.4 nozzle - Copy.json")
dst = Path("KS1C.json")

backup = dst.with_suffix(".json.bak." + datetime.now().strftime("%Y%m%d_%H%M%S"))
shutil.copy2(dst, backup)
print("Backup:", backup)

s = json.loads(src.read_text(encoding="utf-8"))
d = json.loads(dst.read_text(encoding="utf-8"))

for key in [
    "print_host",
    "print_host_webui",
    "printer_agent",
    "host_type",
    "printhost_apikey",
    "printhost_cafile",
]:
    if key in s:
        d[key] = s[key]
        print("copy", key, "=", s[key])

d["name"] = "KS1C"
d["printer_settings_id"] = "KS1C"

dst.write_text(json.dumps(d, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
print("OK: KS1C.json updated")
PY
```

Restart Orca after changing this file.

---

# 11. Test procedure

## 11.1 Verify ACEPRO lane_data

```bash
curl -s "http://192.168.x.x:7125/server/database/item?namespace=lane_data" \
| jq '.result.value | to_entries[] | {lane: .key, material: .value.material, vendor: .value.vendor, sku: .value.sku, spool_id: .value.spool_id}'
```

Expected:

```text
lane1 Sunlu PETG sku 15 spool_id 15
lane2 Sunlu PETG sku 11 spool_id 11
lane3 Sunlu PETG sku 19 spool_id 19
lane4 Sunlu PLA sku 18 spool_id 18
lane5 Sunlu PLA+ sku 2 spool_id 2
lane6 Redline Silky PLA sku 17 spool_id 17
lane7 Sunlu Glow PLA sku 20 spool_id 20
lane8 Polymaker PLA sku 21 spool_id 21
```

## 11.2 Verify Orca loads user presets

```bash
LOG=$(ls -t ~/.config/OrcaSlicer/log/debug_*.log.0 | head -1)
echo "$LOG"

grep -aE "Sunlu - White - 15|Sunlu - Black - 11|Sunlu - Orange - 19|Redline - Silky PLA - 17" "$LOG" | tail -100
```

Expected:

```text
load_presets load preset: Sunlu - White - 15
load_presets load preset: Sunlu - Black - 11
load_presets load preset: Sunlu - Orange - 19
```

## 11.3 Verify Orca patch runs

After opening the Device tab and pressing Filament Sync:

```bash
LOG=$(ls -t ~/.config/OrcaSlicer/log/debug_*.log.0 | head -1)
echo "$LOG"

grep -aE "ACEPRO LaneSync|build_filament_ams_list|sync_ams_list|filament_id not found" "$LOG" | tail -250
```

Expected good log:

```text
ACEPRO LaneSync FINAL: vendor='Sunlu' material='PETG' sku='15' spool_id='15' -> tray_info_idx='Sunlu - White - 15'
build_filament_ams_list: name A1 setting_id Sunlu - White - 15 type PETG
sync_ams_listfinish sync ams list
```

Bad log if the final `PresetBundle.cpp` fix is missing:

```text
sync_ams_list: filament_id Sunlu - White - 15 not found or system or compatible
```

---

# 12. Troubleshooting

## 12.1 Filament Sync button is missing

Possible causes:

```text
1. Physical printer profile is missing printer_agent.
2. Device UI loads, but Moonraker printer agent is not active.
3. Wrong machine profile is selected.
4. Orca was not restarted after editing machine JSON.
```

Check:

```bash
grep -nE '"name"|"print_host"|"print_host_webui"|"printer_agent"|"host_type"|"printer_settings_id"' \
  ~/.config/OrcaSlicer/user/default/machine/KS1C.json
```

## 12.2 Orca syncs only Generic PETG / Generic PLA

Possible causes:

```text
1. User filament presets are missing.
2. JSON internal names do not match filenames.
3. Orca patch is not compiled into the running AppImage.
4. sync_ams_list() still blocks exact user preset names.
```

Check:

```bash
LOG=$(ls -t ~/.config/OrcaSlicer/log/debug_*.log.0 | head -1)
grep -aE "ACEPRO LaneSync|filament_id not found|Generic PETG|Generic PLA" "$LOG" | tail -250
```

## 12.3 Non-numeric SKU still has no spool_id

Check `sku_map`:

```bash
grep -n "sku_map" /home/pi/printer_data/config/saved_variables.cfg
```

Check ACEPRO patch:

```bash
cd ~/ACEPRO

python3 - <<'PY'
from extras.ace.moonraker_lane_sync import MoonrakerLaneSyncAdapter

for sku in ["15", "AHPEVO-102", "AHPLBK-101", "NICHT_GEMAPPT"]:
    print(sku, "->", MoonrakerLaneSyncAdapter._extract_spool_id({"sku": sku}))
PY
```

If the map does not resolve, check:

```text
1. sku_map exists in saved_variables.cfg.
2. The SKU string matches exactly.
3. The ACEPRO patch was applied to the active moonraker_lane_sync.py.
4. Klipper/ACEPRO was restarted.
```

## 12.4 AppImageLauncher crashes

Run extracted:

```bash
cd /tmp
rm -rf orca-ace-run
mkdir orca-ace-run
cd orca-ace-run

~/OrcaSlicer-ACEPRO-LaneSync-FINAL-working.AppImage --appimage-extract >/dev/null
QT_QPA_PLATFORM=xcb ./squashfs-root/AppRun
```

## 12.5 Official Orca update dialog appears

Do not install the official AppImage if this patch is required.

```text
Official Orca AppImage: no ACEPRO SKU/spool_id patch
Self-built patched AppImage: patch included
```

Use `Cancel` or `Skip this version`.

---

# 13. Final working behavior

When everything is correct, pressing Filament Sync in Orca should result in:

```text
A1 -> Sunlu - White - 15
A2 -> Sunlu - Black - 11
A3 -> Sunlu - Orange - 19
A4 -> Sunlu - Carbon Fiber - 18
B1 -> Sunlu - Gold - 2
B2 -> Redline - Silky PLA - 17
B3 -> Sunlu - Blue - 20
B4 -> Polymaker - Transparent - 21
```

This confirms the full chain works:

```text
ACE RFID / Spoolman SKU
→ Rinkhals / ACEPRO inventory
→ ACEPRO sku_map resolves non-numeric RFID SKU
→ Moonraker lane_data contains vendor, sku, spool_id
→ Orca Moonraker printer agent receives lane_data
→ Orca matcher selects preset names by vendor + sku/spool_id
→ tray_info_idx and filament_id contain the preset name
→ sync_ams_list accepts exact f.name matches
→ correct Orca filament presets are selected
```
