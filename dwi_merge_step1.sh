#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# -------------------------------------------------------------------
# Script: dwi_merge_with_best_fieldmap.sh
# Purpose: Merge DWI AP/PA pairs and pick best b=0 fieldmaps by mean brain signal.
#          Logs any fslorient or fslreorient2std failures to WARN_LOG.
# Usage:
#   chmod +x dwi_merge_with_best_fieldmap.sh
#   ./dwi_merge_with_best_fieldmap.sh /path/to/SUBJECT_DIR
# -------------------------------------------------------------------

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/SUBJECT_DIR" >&2
  exit 1
fi

SUBJ="$1"
cd "$SUBJ" || { echo "Cannot cd into $SUBJ" >&2; exit 1; }

# Setup output directory and warning log
mkdir -p dwi_merged
WARN_LOG="../orient_warnings.txt"
touch "$WARN_LOG"

# STEP 1: Create brain mask from the first AP fieldmap
# (we want to mask fieldmap volumes, not DWI volumes)
fm_ap_files=(fieldmap_dwi_ap/*.nii fieldmap_dwi_ap/*.nii.gz)
if [ ${#fm_ap_files[@]} -eq 0 ]; then
  echo "No AP fieldmap files in $SUBJ; skipping fieldmap mask." >&2
  exit 1
fi
first_fm_ap="${fm_ap_files[0]}"
mask="brain_mask.nii.gz"
tmp_fm="first_fm_reorient.nii.gz"

# Reorient and skull-strip to get mask for ranking fieldmaps
if ! fslreorient2std "$first_fm_ap" "$tmp_fm"; then
  echo "$SUBJ/dwi_merged" >> "$WARN_LOG"
else
  bet "$tmp_fm" first_fm_brain -m -R >/dev/null 2>&1 || echo "$SUBJ/dwi_merged" >> "$WARN_LOG"
  mv first_fm_brain_mask.nii.gz "$mask"
fi
rm -f "$tmp_fm" first_fm_brain.nii.gz

# Function: pick file with highest mean signal inside mask
tmp_mean=""
pick_best_b0() {
  local mask="$1"; shift
  local best="" bestm=-1 m
  for f in "$@"; do
    [ -f "$f" ] || continue
    m=$(fslstats "$f" -k "$mask" -M 2>/dev/null || echo -1)
    # float comparison via awk
    if awk -v a="$m" -v b="$bestm" 'BEGIN{exit !(a>b)}'; then
      bestm="$m"; best="$f"
    fi
  done
  echo "$best"
}

# Main loop: merge DWI AP/PA combinations and corresponding fieldmaps
cnt=0
for ap in dwi_ap/*.nii dwi_ap/*.nii.gz; do
  for pa in dwi_pa/*.nii dwi_pa/*.nii.gz; do
    ((cnt++))
    iter="dwi_merged/iteration_${cnt}"
    mkdir -p "$iter"

    # Merge DWI volumes into 4D
    ap_out="$iter/ap.nii.gz"; pa_out="$iter/pa.nii.gz"
    if ! fslreorient2std "$ap" "$ap_out"; then echo "$SUBJ/$iter" >> "$WARN_LOG"; fi
    fslorient -copyqform2sform "$ap_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    fslorient -copysform2qform "$ap_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    if ! fslreorient2std "$pa" "$pa_out"; then echo "$SUBJ/$iter" >> "$WARN_LOG"; fi
    fslorient -copyqform2sform "$pa_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    fslorient -copysform2qform "$pa_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    fslmerge -t "$iter/dwi.nii.gz" "$ap_out" "$pa_out"
    rm -f "$ap_out" "$pa_out"

        # Determine file stubs
    base_ap=$(basename "$ap" .nii.gz)
    base_ap=${base_ap%.nii}
    base_pa=$(basename "$pa" .nii.gz)
    base_pa=${base_pa%.nii}

    # Merge bvals: concatenate AP then PA
    if [ -f "dwi_ap/${base_ap}.bval" ] && [ -f "dwi_pa/${base_pa}.bval" ]; then
      echo "$(cat dwi_ap/${base_ap}.bval) $(cat dwi_pa/${base_pa}.bval)" > "$iter/dwi.bval"
    fi

    # Merge bvecs: each of 3 rows concatenated AP then PA
    if [ -f "dwi_ap/${base_ap}.bvec" ] && [ -f "dwi_pa/${base_pa}.bvec" ]; then
      rm -f "$iter/dwi.bvec"
      for r in 1 2 3; do
        ap_row=$(sed -n "${r}p" dwi_ap/${base_ap}.bvec)
        pa_row=$(sed -n "${r}p" dwi_pa/${base_pa}.bvec)
        echo "$ap_row $pa_row" >> "$iter/dwi.bvec"
      done
    fi

    # Fieldmap: collect candidates by timestamp
    ts=$(echo "$base_ap" | sed -E 's/.*_([0-9]{14})_.*/\1/')
    fm_ap=(); fm_pa=()
    for f in fieldmap_dwi_ap/*_${ts}_*.nii*; do [ -f "$f" ] && fm_ap+=("$f"); done
    for f in fieldmap_dwi_pa/*_${ts}_*.nii*; do [ -f "$f" ] && fm_pa+=("$f"); done

        # Select best fieldmaps: if only one candidate, take it; otherwise pick by mean brain signal
    ap_count=${#fm_ap[@]}
    pa_count=${#fm_pa[@]}
    best_ap=""; best_pa=""
    if [ "$ap_count" -eq 1 ]; then
      best_ap="${fm_ap[0]}"
    elif [ "$ap_count" -gt 1 ]; then
      best_ap=$(pick_best_b0 "$mask" "${fm_ap[@]}")
    fi
    if [ "$pa_count" -eq 1 ]; then
      best_pa="${fm_pa[0]}"
    elif [ "$pa_count" -gt 1 ]; then
      best_pa=$(pick_best_b0 "$mask" "${fm_pa[@]}")
    fi

    # Merge fieldmaps if both selected
    if [ -n "$best_ap" ] && [ -n "$best_pa" ]; then
      fm1="$iter/fm_ap.nii.gz"; fm2="$iter/fm_pa.nii.gz"
      fslreorient2std "$best_ap" "$fm1" && fslorient -copyqform2sform "$fm1" && fslorient -copysform2qform "$fm1"
      fslreorient2std "$best_pa" "$fm2" && fslorient -copyqform2sform "$fm2" && fslorient -copysform2qform "$fm2"
      fslmerge -t "$iter/fieldmap.nii.gz" "$fm1" "$fm2"
      rm -f "$fm1" "$fm2"
    fi
    if [ -n "$best_ap" ] && [ -n "$best_pa" ]; then
      fm1="$iter/fm_ap.nii.gz"; fm2="$iter/fm_pa.nii.gz"
      fslreorient2std "$best_ap" "$fm1" && fslorient -copyqform2sform "$fm1" && fslorient -copysform2qform "$fm1"
      fslreorient2std "$best_pa" "$fm2" && fslorient -copyqform2sform "$fm2" && fslorient -copysform2qform "$fm2"
      fslmerge -t "$iter/fieldmap.nii.gz" "$fm1" "$fm2"
      rm -f "$fm1" "$fm2"
    fi

    echo "Created $SUBJ/$iter"
  done
done

# Final summary & cleanup
echo "Done: $cnt iterations for $SUBJ."
rm -f "$mask"
