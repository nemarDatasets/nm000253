#!/bin/bash
# fix_btb.sh — Pre-upload BIDS validator fixes for BrainTreeBank (nm000253)
# (Wang et al. 2024, braintreebank.dev)
#
# Fixes validator ERRORS introduced by convert_braintreebank.py:
#   1. channels.tsv: add required 'low_cutoff' and 'high_cutoff' columns
#   2. channels.tsv: uppercase 'seeg' → 'SEEG' in type column
#   3. _ieeg.json: add required 'SoftwareFilters' field
#   4. _ieeg.json: add required 'HardwareFilters' field (if missing)
#
# Run idempotently. Archives self into code/ on completion.
#
# Usage: bash fix_btb.sh [path-to-dataset]
set -euo pipefail

DS="${1:-/tmp/btb_recovery/nm000253}"
[[ -d "$DS" ]] || { echo "Not found: $DS"; exit 1; }
cd "$DS"

echo "=== Fix BrainTreeBank at $DS ==="

# -------------------------------------------------------------------
# 1. channels.tsv: add required low_cutoff + high_cutoff columns
#    BIDS-iEEG requires columns: name, type, units, low_cutoff, high_cutoff
# -------------------------------------------------------------------
echo "--- 1. Adding low_cutoff + high_cutoff to channels.tsv ---"
count=0
for f in $(find . -name "*_channels.tsv"); do
  # Only add if not already present
  hdr=$(head -1 "$f")
  if ! echo "$hdr" | grep -q "low_cutoff"; then
    # Raw BTB has no band-pass filter info — use 0.0 and Nyquist/2 as defaults.
    # SFREQ is 2048 Hz → Nyquist is 1024 Hz.
    awk -F'\t' -v OFS='\t' '
      NR == 1 {
        # Insert low_cutoff, high_cutoff after units (col 3)
        printf "%s\t%s\t%s\tlow_cutoff\thigh_cutoff", $1, $2, $3
        for (i=4; i<=NF; i++) printf "\t%s", $i
        printf "\n"
        next
      }
      {
        printf "%s\t%s\t%s\t0.0\t1024", $1, $2, $3
        for (i=4; i<=NF; i++) printf "\t%s", $i
        printf "\n"
      }
    ' "$f" > "${f}.tmp"
    mv "${f}.tmp" "$f"
    count=$((count + 1))
  fi
done
echo "  Added low/high_cutoff to $count channels.tsv"

# -------------------------------------------------------------------
# 2. channels.tsv: uppercase 'seeg' → 'SEEG' in type column
# -------------------------------------------------------------------
echo "--- 2. Uppercasing 'seeg' → 'SEEG' in channels.tsv ---"
count=0
for f in $(find . -name "*_channels.tsv"); do
  if grep -q $'\tseeg\t' "$f" 2>/dev/null; then
    sed -i.bak $'s/\tseeg\t/\tSEEG\t/g' "$f" && rm -f "${f}.bak"
    count=$((count + 1))
  fi
done
echo "  Uppercased type in $count channels.tsv"

# -------------------------------------------------------------------
# 3. _ieeg.json: add required SoftwareFilters field
# -------------------------------------------------------------------
echo "--- 3. Adding SoftwareFilters + HardwareFilters to _ieeg.json ---"
python3 <<'PYEOF'
import json
from pathlib import Path

count = 0
for jp in Path(".").rglob("*_ieeg.json"):
    try:
        with open(jp) as f:
            data = json.load(f)
    except Exception:
        continue
    changed = False
    if "SoftwareFilters" not in data:
        data["SoftwareFilters"] = "n/a"
        changed = True
    if "HardwareFilters" not in data:
        # BrainTreeBank raw at 2048 Hz, no published filter details
        data["HardwareFilters"] = "n/a"
        changed = True
    if "Manufacturer" not in data:
        data["Manufacturer"] = "n/a"
        changed = True
    if "ECOGChannelCount" not in data and "SEEGChannelCount" in data:
        # BIDS wants at least one of these for iEEG
        pass  # already have SEEGChannelCount
    if changed:
        with open(jp, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        count += 1
print(f"  Updated {count} _ieeg.json sidecars")
PYEOF

# -------------------------------------------------------------------
# 3b. Rewrite participants.tsv with ALL subjects found in the tree
# -------------------------------------------------------------------
echo "--- 3b. Rewriting participants.tsv ---"
subjects=$(ls -d sub-* 2>/dev/null | sort)
if [[ -n "$subjects" ]]; then
  {
    echo -e "participant_id\tage\tsex\thand"
    for s in $subjects; do
      echo -e "${s}\tn/a\tn/a\tn/a"
    done
  } > participants.tsv
  n=$(echo "$subjects" | wc -l | tr -d ' ')
  echo "  participants.tsv regenerated with $n subjects"
fi

# -------------------------------------------------------------------
# 3c. Generate _electrodes.tsv per subject using depth-wm.csv from
#     localization.zip (BTB's per-electrode localization). Each
#     depth-wm.csv has columns: Electrode, L, I, P, DesikanKilliany,
#     Destrieux, DKT, ShiftDist, ConfType. L/I/P are voxel indices
#     in the subject's native T1 space.
# -------------------------------------------------------------------
echo "--- 3c. Generating _electrodes.tsv from localization.zip ---"

# Ensure localization data is available
LOC_ZIP=""
if [[ -f code/localization.zip ]]; then
  LOC_ZIP=code/localization.zip
elif [[ -f /tmp/localization.zip ]]; then
  LOC_ZIP=/tmp/localization.zip
  cp /tmp/localization.zip code/localization.zip 2>/dev/null || true
else
  echo "  ERROR: localization.zip missing. Fetching from braintreebank.dev..."
  /usr/bin/curl -sL --max-time 60 -o code/localization.zip \
    "https://braintreebank.dev/data/localization.zip"
  LOC_ZIP=code/localization.zip
fi

rm -rf /tmp/btb_localization
mkdir -p /tmp/btb_localization
unzip -q -o "$LOC_ZIP" -d /tmp/btb_localization

python3 <<'PYEOF'
import csv
from pathlib import Path

count = 0
for sub_path in sorted(Path(".").glob("sub-*")):
    sub_id = sub_path.name.replace("sub-", "").lstrip("0") or "0"
    # Source file: /tmp/btb_localization/localization/sub_<id>/depth-wm.csv
    src_csv = Path(f"/tmp/btb_localization/localization/sub_{int(sub_id)}/depth-wm.csv")
    if not src_csv.exists():
        print(f"  sub-{int(sub_id):02d}: localization CSV not found, skipping")
        continue

    # Read the localization CSV: name → (L, I, P, DKT label)
    loc = {}
    with open(src_csv, encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row["Electrode"]
            # Clean the name the same way the converter did
            cleaned = name.replace("*", "x").replace("/", "-").replace(" ", "")
            loc[cleaned] = {
                "x": row["L"],
                "y": row["I"],
                "z": row["P"],
                "desikan": row.get("DesikanKilliany", "n/a"),
                "destrieux": row.get("Destrieux", "n/a"),
                "dkt": row.get("DKT", "n/a"),
            }

    # Pick any channels.tsv from this subject to get the channel list
    ch_files = sorted(sub_path.rglob("*_channels.tsv"))
    if not ch_files:
        continue
    # utf-8-sig strips BOM if present
    with open(ch_files[0], encoding="utf-8-sig") as f:
        chan_reader = csv.DictReader(f, delimiter="\t")
        ch_names = [row["name"] for row in chan_reader if row.get("type") == "SEEG"]

    # Build electrodes.tsv
    elec_file = sub_path / "ieeg" / f"sub-{int(sub_id):02d}_electrodes.tsv"
    elec_file.parent.mkdir(parents=True, exist_ok=True)
    with open(elec_file, "w") as f:
        f.write("name\tx\ty\tz\tsize\tmaterial\themisphere\ttype\tregion_desikan\tregion_destrieux\tregion_dkt\n")
        matched = 0
        for n in ch_names:
            info = loc.get(n)
            if info:
                # Derive hemisphere from anatomical label prefix (ctx-lh- / ctx-rh-)
                reg = info["desikan"]
                hemi = "L" if "lh" in reg else ("R" if "rh" in reg else "n/a")
                # Electrode material is NOT stated in the Brain Treebank paper
                # or code release. Leave as n/a rather than inferring from
                # general BCH clinical practice.
                f.write(f"{n}\t{info['x']}\t{info['y']}\t{info['z']}\tn/a\tn/a\t{hemi}\tdepth\t{info['desikan']}\t{info['destrieux']}\t{info['dkt']}\n")
                matched += 1
            else:
                f.write(f"{n}\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tdepth\tn/a\tn/a\tn/a\n")
        total = len(ch_names)
    print(f"  sub-{int(sub_id):02d}: electrodes.tsv written with {matched}/{total} coordinates matched")
    count += 1

print(f"\n  Total subjects with electrodes.tsv: {count}")

# Write a root electrodes.json sidecar that declares the extra columns
# (hemisphere, type, region_desikan, region_destrieux, region_dkt)
import json as _json
with open("electrodes.json", "w") as _f:
    _json.dump({
        "name": {"Description": "Electrode name (matches channels.tsv)"},
        "x": {"Description": "Value from Brain Treebank depth-wm.csv column 'L' (presumably Left axis). Units / origin / template NOT documented in the Brain Treebank release — see coordsystem.json.", "Units": "n/a"},
        "y": {"Description": "Value from Brain Treebank depth-wm.csv column 'I' (presumably Inferior axis). Units / origin / template NOT documented in the Brain Treebank release.", "Units": "n/a"},
        "z": {"Description": "Value from Brain Treebank depth-wm.csv column 'P' (presumably Posterior axis). Units / origin / template NOT documented in the Brain Treebank release.", "Units": "n/a"},
        "size": {"Description": "Contact surface area", "Units": "mm^2"},
        "material": {"Description": "Contact material"},
        "hemisphere": {"Description": "Brain hemisphere of the contact (L or R)", "Levels": {"L": "Left", "R": "Right", "n/a": "unknown"}},
        "type": {"Description": "Electrode type (depth / grid / strip)", "Levels": {"depth": "stereotactic EEG depth electrode", "grid": "subdural grid", "strip": "subdural strip", "n/a": "unknown"}},
        "region_desikan": {"Description": "Anatomical region label from the FreeSurfer Desikan-Killiany parcellation"},
        "region_destrieux": {"Description": "Anatomical region label from the FreeSurfer Destrieux parcellation"},
        "region_dkt": {"Description": "Anatomical region label from the FreeSurfer DKT parcellation"},
    }, _f, indent=2)
    _f.write("\n")
print("  electrodes.json root sidecar written")
PYEOF

# -------------------------------------------------------------------
# 3d. Generate _coordsystem.json for each subject with electrodes.tsv
#     Coordinates are native T1 voxel indices (L, I, P axes).
# -------------------------------------------------------------------
echo "--- 3d. Generating _coordsystem.json for iEEG subjects ---"
count=0
for elec in $(find . -name "*_electrodes.tsv"); do
  dir=$(dirname "$elec")
  base=$(basename "$elec" _electrodes.tsv)
  coord="${dir}/${base}_coordsystem.json"
  # Always overwrite with the correct content
  cat > "$coord" <<'EOF'
{
  "iEEGCoordinateSystem": "Other",
  "iEEGCoordinateUnits": "n/a",
  "iEEGCoordinateSystemDescription": "Electrode positions as reported in Brain Treebank's localization.zip, file 'localization/sub_<id>/depth-wm.csv'. The CSV was produced by iELVis (Groppe et al. 2017) + BioImageSuite after co-registering a post-operative fluoroscopy scan to the pre-operative T1 MRI. The axes are labelled L, I, P in the source CSV (presumably Left, Inferior, Posterior), and anatomical region labels come from FreeSurfer parcellations (Desikan-Killiany, Destrieux, DKT) included as extra columns in electrodes.tsv. IMPORTANT: the Brain Treebank release does NOT publish the coordinate units, origin, or the transform to a standard template (MNI, ACPC, ScanRAS, or FreeSurfer surface RAS). Users requiring cross-subject alignment or millimetre distances should consult the original Brain Treebank publication and code release, and/or contact the authors for the co-registration matrices. These coordinates are provided as-is from depth-wm.csv for reproducibility; no transform has been applied in this dataset.",
  "iEEGCoordinateProcessingDescription": "Post-operative fluoroscopy scan co-registered to pre-operative T1 MRI using iELVis. Electrodes manually identified in BioImageSuite and assigned to FreeSurfer atlases (Desikan-Killiany, Destrieux, DKT). For electrodes located in white matter, contacts were projected to the nearest grey/white matter boundary — the 'ShiftDist' column in the source depth-wm.csv records the projection distance.",
  "iEEGCoordinateProcessingReference": "iELVis — doi:10.1016/j.jneumeth.2017.01.022; Brain Treebank — doi:10.48550/arXiv.2411.08343"
}
EOF
  count=$((count + 1))
done
echo "  Created/updated $count _coordsystem.json files"

# Clean up unzip dir
rm -rf /tmp/btb_localization

# Copy localization.zip into code/ for provenance
[[ -f code/localization.zip ]] || cp /tmp/localization.zip code/localization.zip 2>/dev/null || true

# -------------------------------------------------------------------
# 4. Archive this script into code/ for provenance
# -------------------------------------------------------------------
echo "--- 4. Archiving fix script into code/ ---"
mkdir -p code
SELF="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
[[ -f "$SELF" ]] && cp -f "$SELF" code/fix_btb.sh
chmod +x code/fix_btb.sh 2>/dev/null || true
echo "  archived → code/fix_btb.sh"

echo ""
echo "=== Done ==="
echo "Re-run validator with:"
echo "  nemar dataset validate --prune $DS"
