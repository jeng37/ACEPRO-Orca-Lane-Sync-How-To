#!/usr/bin/env bash
set -euo pipefail

# OrcaSlicer ACEPRO/Rinkhals Moonraker LaneSync SKU/spool_id all-in-one
# Clone -> PR #13719 -> patch -> build AppImage.
#
# Usage:
#   chmod +x orca_acepro_lanesync_all_in_one_build.sh
#   ./orca_acepro_lanesync_all_in_one_build.sh
#
# Optional env:
#   ORCA_DIR="$HOME/OrcaSlicer-test" JOBS=8 DO_BUILD=1 FIX_USER_FILAMENTS=0 ./orca_acepro_lanesync_all_in_one_build.sh

REPO_URL="${REPO_URL:-https://github.com/OrcaSlicer/OrcaSlicer.git}"
PR_NUMBER="${PR_NUMBER:-13719}"
PR_BRANCH="${PR_BRANCH:-pr-${PR_NUMBER}-moonraker-vendor-match}"
ORCA_DIR="${ORCA_DIR:-$HOME/OrcaSlicer}"
FINAL_APPIMAGE="${FINAL_APPIMAGE:-$HOME/OrcaSlicer-ACEPRO-LaneSync-FINAL-working.AppImage}"
PATCH_OUT="${PATCH_OUT:-$HOME/orca_acepro_lanesync_sku_spoolid_final.patch}"
DO_BUILD="${DO_BUILD:-1}"
FIX_USER_FILAMENTS="${FIX_USER_FILAMENTS:-0}"

for c in git python3 nproc nice; do
  command -v "$c" >/dev/null 2>&1 || { echo "[FEHLER] fehlt: $c"; exit 1; }
done

if [[ -z "${JOBS:-}" ]]; then
  JOBS=$(( $(nproc) / 2 ))
  [[ "$JOBS" -lt 1 ]] && JOBS=1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"

if [[ -e "$ORCA_DIR" ]]; then
  BACKUP="${ORCA_DIR}_backup_before_acepro_${STAMP}"
  echo "[WARN] $ORCA_DIR existiert, verschiebe nach $BACKUP"
  mv "$ORCA_DIR" "$BACKUP"
fi

echo "[INFO] Clone $REPO_URL -> $ORCA_DIR"
git clone "$REPO_URL" "$ORCA_DIR"
cd "$ORCA_DIR"

echo "[INFO] Fetch PR #$PR_NUMBER"
git fetch origin "pull/${PR_NUMBER}/head:${PR_BRANCH}"
git checkout "$PR_BRANCH"
git status -sb

echo "[INFO] Patch source..."
python3 - <<'PY'
from pathlib import Path
import re

root = Path.cwd()
cpp_path = root / "src/slic3r/Utils/MoonrakerPrinterAgent.cpp"
pb_path  = root / "src/libslic3r/PresetBundle.cpp"

cpp = cpp_path.read_text(encoding="utf-8")
pb  = pb_path.read_text(encoding="utf-8")

def find_matching_brace(text, open_pos):
    depth = 0
    i = open_pos
    state = "code"
    while i < len(text):
        c = text[i]
        n = text[i+1] if i+1 < len(text) else ""
        if state == "code":
            if c == "/" and n == "/":
                state = "line"; i += 2; continue
            if c == "/" and n == "*":
                state = "block"; i += 2; continue
            if c == '"':
                state = "str"; i += 1; continue
            if c == "'":
                state = "chr"; i += 1; continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return i
        elif state == "line":
            if c == "\n": state = "code"
        elif state == "block":
            if c == "*" and n == "/":
                state = "code"; i += 2; continue
        elif state == "str":
            if c == "\\":
                i += 2; continue
            if c == '"': state = "code"
        elif state == "chr":
            if c == "\\":
                i += 2; continue
            if c == "'": state = "code"
        i += 1
    return -1

def patch_function(text, sig_regex, patcher):
    m = re.search(sig_regex, text, re.M | re.S)
    if not m:
        raise SystemExit(f"[FEHLER] Funktion nicht gefunden: {sig_regex}")
    open_pos = text.find("{", m.start())
    close_pos = find_matching_brace(text, open_pos)
    if close_pos < 0:
        raise SystemExit("[FEHLER] Funktionsende nicht gefunden")
    func = text[m.start():close_pos+1]
    new_func = patcher(func)
    return text[:m.start()] + new_func + text[close_pos+1:]

# 1) Payload: tray_info_idx zusätzlich als filament_id exportieren.
payload_marker = "ACEPRO: expose tray_info_idx also as filament_id for Orca AMS sync"
def patch_payload(func):
    if payload_marker in func:
        print("[OK] build_ams_payload already patched")
        return func
    a = '                tray_json["tray_info_idx"] = tray->tray_info_idx;\n'
    b = '                tray_json["tray_info_idx"] = "";\n'
    if a not in func or b not in func:
        raise SystemExit("[FEHLER] build_ams_payload tray_info_idx Zeilen nicht gefunden")
    func = func.replace(a, a + f'                // {payload_marker}\n                tray_json["filament_id"] = tray->tray_info_idx;\n', 1)
    func = func.replace(b, b + f'                // {payload_marker}\n                tray_json["filament_id"] = "";\n', 1)
    print("[OK] build_ams_payload patched")
    return func

cpp = patch_function(
    cpp,
    r'void\s+MoonrakerPrinterAgent::build_ams_payload\s*\([^)]*\)\s*\{',
    patch_payload
)

# 2) Moonraker lane_data: vendor + sku/spool_id -> Orca Preset-NAME matchen.
fetch_marker = "ACEPRO LaneSync FINAL sku/spool_id preset-name override"
def patch_fetch(func):
    if fetch_marker in func:
        print("[OK] fetch_moonraker_filament_data already patched")
        return func

    m = re.search(r'(?m)^(?P<i>[ \t]*)trays\.push_back\s*\(\s*tray\s*\)\s*;', func)
    if not m:
        raise SystemExit("[FEHLER] trays.push_back(tray) nicht gefunden")
    i = m.group("i")
    def I(x=""): return i + x

    block = "\n".join([
I("// ACEPRO LaneSync FINAL sku/spool_id preset-name override"),
I("{"),
I("    auto* ace_bundle = GUI::wxGetApp().preset_bundle;"),
I("    auto to_str = [](const nlohmann::json& obj, const char* key) -> std::string {"),
I("        auto it = obj.find(key);"),
I("        if (it == obj.end() || it->is_null()) return \"\";"),
I("        if (it->is_string()) return it->get<std::string>();"),
I("        if (it->is_number_integer() || it->is_number_unsigned()) return std::to_string(it->get<long long>());"),
I("        if (it->is_number_float()) { double v = it->get<double>(); long long iv = static_cast<long long>(v); if (static_cast<double>(iv) == v) return std::to_string(iv); }"),
I("        return \"\";"),
I("    };"),
I("    auto norm = [](std::string s) -> std::string {"),
I("        std::string out; out.reserve(s.size());"),
I("        for (unsigned char c : s) {"),
I("            if (c >= 'a' && c <= 'z') out.push_back(static_cast<char>(c - 'a' + 'A'));"),
I("            else if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) out.push_back(static_cast<char>(c));"),
I("            else out.push_back(' ');"),
I("        }"),
I("        boost::algorithm::trim(out);"),
I("        std::string r; bool sp = false;"),
I("        for (unsigned char c : out) { bool ws = (c == ' ' || c == '\\t' || c == '\\n' || c == '\\r'); if (ws) { if (!sp) r.push_back(' '); sp = true; } else { r.push_back(static_cast<char>(c)); sp = false; } }"),
I("        boost::algorithm::trim(r); return r;"),
I("    };"),
I("    auto contains = [&](const std::string& text, const std::string& needle) -> bool { auto t = norm(text); auto n = norm(needle); return !t.empty() && !n.empty() && t.find(n) != std::string::npos; };"),
I("    auto token = [&](const std::string& text, const std::string& tok) -> bool { auto t = \" \" + norm(text) + \" \"; auto n = \" \" + norm(tok) + \" \"; return n.size() > 2 && t.find(n) != std::string::npos; };"),
I("    auto first_token = [&](const std::string& text) -> std::string { auto n = norm(text); auto p = n.find(' '); return p == std::string::npos ? n : n.substr(0, p); };"),
I(""),
I("    std::string vendor = safe_json_string(lane_obj, \"vendor\");"),
I("    if (vendor.empty()) vendor = safe_json_string(lane_obj, \"manufacturer\");"),
I("    if (vendor.empty()) vendor = safe_json_string(lane_obj, \"brand\");"),
I("    const std::string sku = to_str(lane_obj, \"sku\");"),
I("    const std::string spool_id = to_str(lane_obj, \"spool_id\");"),
I("    std::string lane_name = safe_json_string(lane_obj, \"filament_settings_id\");"),
I("    if (lane_name.empty()) lane_name = safe_json_string(lane_obj, \"filament_id\");"),
I("    if (lane_name.empty()) lane_name = safe_json_string(lane_obj, \"name\");"),
I("    if (lane_name.empty()) lane_name = safe_json_string(lane_obj, \"filament_name\");"),
I(""),
I("    auto exact = [&](const std::string& candidate) -> std::string {"),
I("        if (!ace_bundle || candidate.empty()) return \"\";"),
I("        for (const Preset& preset : ace_bundle->filaments.get_presets()) { if (preset.name == candidate || preset.filament_id == candidate) return preset.name; }"),
I("        if (const Preset* p = ace_bundle->filaments.find_preset(candidate, false)) return p->name;"),
I("        if (const Preset* p = ace_bundle->filaments.find_preset(candidate, true)) return p->name;"),
I("        return \"\";"),
I("    };"),
I("    auto best = [&](bool require_vendor, bool require_id) -> std::string {"),
I("        if (!ace_bundle) return \"\";"),
I("        int best_score = -1000000; std::string best_name;"),
I("        for (const Preset& preset : ace_bundle->filaments.get_presets()) {"),
I("            bool id_ok = (!sku.empty() && token(preset.name, sku)) || (!spool_id.empty() && token(preset.name, spool_id));"),
I("            if (require_id && !id_ok) continue;"),
I("            bool vendor_ok = vendor.empty() || contains(preset.name, vendor);"),
I("            if (!vendor_ok) { auto v = first_token(vendor); vendor_ok = !v.empty() && token(preset.name, v); }"),
I("            if (require_vendor && !vendor_ok) continue;"),
I("            int score = 0;"),
I("            if (id_ok) score += 1000;"),
I("            if (vendor_ok && !vendor.empty()) score += 300;"),
I("            if (!lane_name.empty() && contains(preset.name, lane_name)) score += 200;"),
I("            if (!tray.tray_type.empty() && token(preset.name, tray.tray_type)) score += 100;"),
I("            if (boost::istarts_with(preset.name, \"Generic \")) score -= 500;"),
I("            if (score > best_score) { best_score = score; best_name = preset.name; }"),
I("        }"),
I("        return best_name;"),
I("    };"),
I(""),
I("    std::string matched = exact(lane_name);"),
I("    if (matched.empty()) matched = best(true, true);"),
I("    if (matched.empty()) matched = best(false, true);"),
I("    if (matched.empty()) matched = best(true, false);"),
I("    if (!matched.empty()) {"),
I("        tray.tray_info_idx = matched;"),
I("        BOOST_LOG_TRIVIAL(info) << \"ACEPRO LaneSync FINAL: vendor='\" << vendor << \"' material='\" << tray.tray_type << \"' sku='\" << sku << \"' spool_id='\" << spool_id << \"' -> tray_info_idx='\" << tray.tray_info_idx << \"'\";"),
I("    }"),
I("}"),
"",
    ])
    print("[OK] fetch_moonraker_filament_data patched")
    return func[:m.start()] + block + func[m.start():]

cpp = patch_function(
    cpp,
    r'bool\s+MoonrakerPrinterAgent::fetch_moonraker_filament_data\s*\(\s*std::vector<AmsTrayData>&\s+trays\s*,\s*int&\s+max_lane_index\s*\)\s*\{',
    patch_fetch
)

cpp_path.write_text(cpp, encoding="utf-8")

# 3) PresetBundle: exakte Preset-Namen akzeptieren, ohne compatible/base-Blockade.
before = pb

pb = re.sub(
    r'return\s+f\.is_compatible\s*&&\s*filaments\.get_preset_base\(f\)\s*==\s*&f\s*&&\s*\(?\s*f\.filament_id\s*==\s*filament_id\s*(?:\|\|\s*f\.name\s*==\s*filament_id\s*)?\)?\s*;',
    'return f.filament_id == filament_id || f.name == filament_id;',
    pb
)

# Falls PR schon teilweise gepatcht war:
pb = pb.replace(
    'return f.is_compatible && filaments.get_preset_base(f) == &f && (f.filament_id == filament_id || f.name == filament_id);',
    'return f.filament_id == filament_id || f.name == filament_id;'
)

if "f.name == filament_id" not in pb:
    raise SystemExit("[FEHLER] PresetBundle patch nicht sichtbar")

pb_path.write_text(pb, encoding="utf-8")
print("[OK] PresetBundle patched")
PY

echo
echo "[INFO] Patch-Checks:"
grep -n "ACEPRO LaneSync FINAL" src/slic3r/Utils/MoonrakerPrinterAgent.cpp || true
grep -n "expose tray_info_idx also as filament_id" src/slic3r/Utils/MoonrakerPrinterAgent.cpp || true
grep -n "f\.filament_id == filament_id\|f.name == filament_id" src/libslic3r/PresetBundle.cpp || true

echo
echo "[INFO] git diff --check"
git diff --check

echo
echo "[INFO] Schreibe finalen Patch: $PATCH_OUT"
git diff > "$PATCH_OUT"
ls -lh "$PATCH_OUT"

if [[ "$FIX_USER_FILAMENTS" == "1" ]]; then
  echo
  echo "[INFO] Repariere vorhandene Orca User-Filamentprofile..."
  python3 - <<'PY'
import json, shutil, time
from pathlib import Path
from datetime import datetime

root = Path.home() / ".config" / "OrcaSlicer" / "user" / "default" / "filament"
if not root.exists():
    print("[WARN] Nicht gefunden:", root)
    raise SystemExit(0)

backup = root.parent / ("filament_backup_before_acepro_allinone_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
shutil.copytree(root, backup)
print("[OK] Backup:", backup)

for p in root.glob("*.json"):
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print("[WARN] skip", p.name, e)
        continue
    data["name"] = p.stem
    data.pop("filament_id", None)
    data["compatible_printers"] = []
    data["compatible_printers_condition"] = ""
    data["compatible_prints"] = []
    data["compatible_prints_condition"] = ""
    p.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
    print("[OK]", p.name)

for p in root.glob("*.info"):
    p.write_text("\n".join([
        "sync_info = create",
        "user_id = ",
        "setting_id = ",
        "base_id = ",
        f"updated_time = {int(time.time())}",
        ""
    ]), encoding="utf-8")
    print("[OK]", p.name)
PY
fi

if [[ "$DO_BUILD" != "1" ]]; then
  echo "[OK] DO_BUILD=0, Build übersprungen."
  exit 0
fi

echo
echo "[INFO] Build startet, Jobs=$JOBS"
nice -n 10 ./build_linux.sh -dsti -j "$JOBS"

APPIMAGE=""
if [[ -f "$ORCA_DIR/build/OrcaSlicer_Linux_V2.4.0-dev.AppImage" ]]; then
  APPIMAGE="$ORCA_DIR/build/OrcaSlicer_Linux_V2.4.0-dev.AppImage"
else
  APPIMAGE="$(find "$ORCA_DIR/build" -maxdepth 1 -type f -name "*.AppImage" ! -name "appimagetool.AppImage" | head -1 || true)"
fi

if [[ -z "$APPIMAGE" || ! -f "$APPIMAGE" ]]; then
  echo "[FEHLER] Build fertig, aber keine AppImage gefunden."
  exit 1
fi

cp -f "$APPIMAGE" "$FINAL_APPIMAGE"
chmod +x "$FINAL_APPIMAGE"

echo
echo "[OK] Fertig."
echo "[OK] AppImage: $FINAL_APPIMAGE"
echo "[OK] Patch:    $PATCH_OUT"
echo
echo "Start ohne AppImageLauncher:"
echo "  cd /tmp"
echo "  rm -rf orca-ace-run"
echo "  mkdir orca-ace-run && cd orca-ace-run"
echo "  \"$FINAL_APPIMAGE\" --appimage-extract >/dev/null"
echo "  QT_QPA_PLATFORM=xcb ./squashfs-root/AppRun"
