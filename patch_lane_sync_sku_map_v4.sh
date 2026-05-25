#!/usr/bin/env bash
set -euo pipefail

# V4 Patch: ACEPRO / Moonraker lane_sync SKU -> Spoolman-ID mapping
#
# Fix:
#   - numerische SKU, z.B. "15" -> spool_id 15
#   - gemappte SKU, z.B. "AHPEVO-102" -> sku_map["AHPEVO-102"] -> spool_id 19
#
# Wichtig:
#   Diese Version patcht nur die Datei und prueft die Python-Syntax.
#   Kein fehleranfaelliger Self-Test mehr.
#
# Nutzung:
#   cd ~/ACEPRO/extras/ace
#   chmod +x patch_lane_sync_sku_map_v4.sh
#   ./patch_lane_sync_sku_map_v4.sh ./moonraker_lane_sync.py

TARGET="${1:-./moonraker_lane_sync.py}"

if [[ ! -f "$TARGET" ]]; then
  echo "[FEHLER] Datei nicht gefunden: $TARGET"
  echo "Nutzung:"
  echo "  $0 ./moonraker_lane_sync.py"
  exit 1
fi

BACKUP="${TARGET}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "$TARGET" "$BACKUP"

echo "[INFO] Ziel:   $TARGET"
echo "[INFO] Backup: $BACKUP"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

target = Path(sys.argv[1])
text = target.read_text(encoding="utf-8")

# Entfernt wahlweise:
#   - alten V2 Block: def _load_sku_map(self) + def _extract_spool_id(self, inv)
#   - alten/originalen Block: @staticmethod def _extract_spool_id(inv)
#   - V3 Block: @staticmethod def _extract_spool_id(inv)
# bis direkt vor _rgb_to_hex().
pattern = re.compile(
    r'\n(?P<indent>[ \t]*)'
    r'(?:'
    r'def _load_sku_map\(self\):'
    r'|@staticmethod[ \t]*\n(?P=indent)def _extract_spool_id\(inv\):'
    r'|def _extract_spool_id\(self,\s*inv\):'
    r'|def _extract_spool_id\(inv\):'
    r')'
    r'.*?'
    r'(?=\n(?P=indent)@staticmethod[ \t]*\n(?P=indent)def _rgb_to_hex\(rgb\):)',
    re.DOTALL,
)

m = pattern.search(text)
if not m:
    print("[FEHLER] Konnte den _extract_spool_id Block nicht finden.")
    print("        Fundstellen:")
    for mm in re.finditer(r'_extract_spool_id|_rgb_to_hex|_load_sku_map', text):
        line_no = text[:mm.start()].count("\n") + 1
        print(f"        - {mm.group(0)} bei Zeile {line_no}")
    raise SystemExit(2)

indent = m.group("indent")

def I(s=""):
    return indent + s

new_block = "\n" + "\n".join([
I("@staticmethod"),
I("def _extract_spool_id(inv):"),
I("    # Spoolman-ID fuer lane_data ermitteln."),
I("    # Reihenfolge:"),
I("    #   1. inv['spool_id'], falls vorhanden"),
I("    #   2. numerische SKU direkt als spool_id"),
I("    #   3. nicht-numerische SKU ueber sku_map aus saved_variables.cfg"),
I("    import ast"),
I("    import os"),
I(""),
I("    def load_sku_map():"),
I("        paths = []"),
I(""),
I("        env_path = os.environ.get(\"ACE_SAVED_VARIABLES\")"),
I("        if env_path:"),
I("            paths.append(env_path)"),
I(""),
I("        paths.append(\"/home/pi/printer_data/config/saved_variables.cfg\")"),
I("        paths.append(\"/home/pi/klipper_config/saved_variables.cfg\")"),
I("        paths.append(\"/useremain/home/rinkhals/printer_data/config/saved_variables.cfg\")"),
I("        paths.append(\"/useremain/home/jeng/printer_data/config/saved_variables.cfg\")"),
I(""),
I("        for path in paths:"),
I("            try:"),
I("                if not path or not os.path.exists(path):"),
I("                    continue"),
I(""),
I("                with open(path, \"r\", encoding=\"utf-8\") as f:"),
I("                    for raw_line in f:"),
I("                        line = raw_line.strip()"),
I("                        if not line.startswith(\"sku_map\"):"),
I("                            continue"),
I(""),
I("                        _, value = line.split(\"=\", 1)"),
I("                        loaded = ast.literal_eval(value.strip())"),
I("                        if not isinstance(loaded, dict):"),
I("                            return {}"),
I(""),
I("                        result = {}"),
I("                        for key, val in loaded.items():"),
I("                            key = str(key).strip()"),
I("                            if not key:"),
I("                                continue"),
I("                            try:"),
I("                                result[key] = int(val)"),
I("                            except Exception:"),
I("                                continue"),
I("                        return result"),
I(""),
I("            except Exception:"),
I("                continue"),
I(""),
I("        return {}"),
I(""),
I("    direct = inv.get(\"spool_id\")"),
I("    if isinstance(direct, int):"),
I("        return direct"),
I("    if isinstance(direct, str) and direct.strip().isdigit():"),
I("        try:"),
I("            return int(direct.strip())"),
I("        except Exception:"),
I("            pass"),
I(""),
I("    sku = inv.get(\"sku\")"),
I("    if sku is None:"),
I("        return None"),
I(""),
I("    if isinstance(sku, int):"),
I("        return sku"),
I(""),
I("    sku = str(sku).strip()"),
I("    if not sku:"),
I("        return None"),
I(""),
I("    if sku.isdigit():"),
I("        try:"),
I("            return int(sku)"),
I("        except Exception:"),
I("            return None"),
I(""),
I("    sku_map = load_sku_map()"),
I("    mapped = sku_map.get(sku)"),
I("    if mapped is None:"),
I("        mapped = sku_map.get(sku.upper())"),
I("    if mapped is None:"),
I("        mapped = sku_map.get(sku.lower())"),
I(""),
I("    if mapped is not None:"),
I("        try:"),
I("            return int(mapped)"),
I("        except Exception:"),
I("            return None"),
I(""),
I("    return None"),
""
])

new_text = text[:m.start()] + new_block + text[m.end():]
target.write_text(new_text, encoding="utf-8")
print("[OK] _extract_spool_id() mit sku_map Mapping eingebaut.")
PY

if ! python3 -m py_compile "$TARGET"; then
  echo "[FEHLER] Syntaxcheck fehlgeschlagen. Backup wird wiederhergestellt."
  cp -a "$BACKUP" "$TARGET"
  exit 1
fi

echo "[OK] Syntaxcheck bestanden."

echo
echo "[INFO] Patchstelle:"
grep -n -A90 "_extract_spool_id" "$TARGET" | sed -n '1,110p'

echo
echo "Jetzt neu starten:"
echo "  sudo systemctl restart klipper"
echo
echo "Dann pruefen:"
echo "  curl -s \"http://192.168.8.8:7125/server/database/item?namespace=lane_data\" | jq '.result.value | to_entries[] | {lane: .key, sku: .value.sku, spool_id: .value.spool_id}'"
