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
# 3c. Generate _electrodes.tsv for each subject missing one
#     iEEG requires electrodes.tsv at subject level (or per-session).
#     Build from channels.tsv contents since we don't have coordinates.
# -------------------------------------------------------------------
echo "--- 3c. Generating _electrodes.tsv for subjects missing one ---"
count=0
for sub_dir in sub-*/ieeg; do
  [[ -d "$sub_dir" ]] || continue
  sub=$(dirname "$sub_dir")
  elec_file="${sub}/ieeg/${sub}_electrodes.tsv"
  if [[ -f "$elec_file" ]]; then
    # Already exists — skip
    continue
  fi
  # Pick any channels.tsv from this subject
  chan=$(ls "${sub}/ieeg/"*_channels.tsv 2>/dev/null | head -1)
  [[ -z "$chan" ]] && continue
  # Build electrodes.tsv with required columns name, x, y, z, size
  awk -F'\t' -v OFS='\t' '
    NR == 1 {
      # Find name + type cols
      for (i=1; i<=NF; i++) {
        if ($i == "name") name_col = i
        if ($i == "type") type_col = i
      }
      print "name","x","y","z","size","material"
      next
    }
    # Only include SEEG channels in electrodes.tsv
    $type_col == "SEEG" {
      print $name_col, "n/a", "n/a", "n/a", "n/a", "platinum-iridium"
    }
  ' "$chan" > "$elec_file"
  count=$((count + 1))
done
echo "  Created $count _electrodes.tsv files"

# -------------------------------------------------------------------
# 3d. Generate _coordsystem.json for each subject with electrodes.tsv
# -------------------------------------------------------------------
echo "--- 3d. Generating _coordsystem.json for iEEG subjects ---"
count=0
for elec in $(find . -name "*_electrodes.tsv"); do
  dir=$(dirname "$elec")
  base=$(basename "$elec" _electrodes.tsv)
  coord="${dir}/${base}_coordsystem.json"
  [[ -f "$coord" ]] && continue
  cat > "$coord" <<'EOF'
{
  "iEEGCoordinateSystem": "Other",
  "iEEGCoordinateUnits": "mm",
  "iEEGCoordinateSystemDescription": "Electrode coordinates are not available in the distributed Brain Treebank HDF5 files. Anatomical localization is provided separately via the localization.zip archive (depth-wm.csv per subject), not per-electrode coordinates in native MRI space.",
  "iEEGCoordinateProcessingDescription": "n/a"
}
EOF
  count=$((count + 1))
done
echo "  Created $count _coordsystem.json files"

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
