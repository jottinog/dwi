#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# -------------------------------------------------------------------
# Script: dwi_merge_with_best_fieldmap.sh
# Purpose: Merge DWI AP/PA pairs and pick best b=0 images (fieldmaps)
#          by mean brain signal, merging into fieldmap.nii.gz.
#          Logs any fslorient or fslreorient2std failures to WARN_LOG.
# Usage:
#   chmod +x dwi_merge_with_best_fieldmap.sh
#   ./dwi_merge_with_best_fieldmap.sh /path/to/SUBJECT_DIR
# -------------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/SUBJECT_DIR" >&2; exit 1
fi

SUBJ="$1"
cd "$SUBJ" || { echo "Cannot cd into $SUBJ" >&2; exit 1; }

# Setup output and warning log
mkdir -p dwi_merged
WARN_LOG="../orient_warnings.txt"
touch "$WARN_LOG"

# STEP A: Create brain mask from first AP b=0, then remove temp files
ap_files=(dwi_ap/*.nii dwi_ap/*.nii.gz)
if [ ${#ap_files[@]} -eq 0 ]; then
  echo "No DWI AP files in $SUBJ; skipping." >&2; exit 0
fi
first_ap="${ap_files[0]}"
mask="brain_mask.nii.gz"
tmp="first_ap_reorient.nii.gz"

# Reorient then skull-strip
if ! fslreorient2std "$first_ap" "$tmp"; then
  echo "$SUBJ/dwi_merged" >> "$WARN_LOG"
else
  bet "$tmp" first_ap_brain -m -R >/dev/null 2>&1 || echo "$SUBJ/dwi_merged" >> "$WARN_LOG"
  mv first_ap_brain_mask.nii.gz "$mask"
  rm -f first_ap_brain.nii.gz
fi
rm -f "$tmp"

# Function: pick file with highest mean inside mask
tmp_mean=""
pick_best_b0() {
  local mask="$1"; shift; local best="" bestm=-1
  for f in "$@"; do
    [ -f "$f" ] || continue
    m=$(fslstats "$f" -k "$mask" -M 2>/dev/null || echo -1)
    [ "$m" -gt "$bestm" ] && { bestm="$m"; best="$f"; }
  done
  echo "$best"
}

# Main merge loop
cnt=0
for ap in dwi_ap/*.nii dwi_ap/*.nii.gz; do
  for pa in dwi_pa/*.nii dwi_pa/*.nii.gz; do
    ((cnt++))
    iter="dwi_merged/iteration_${cnt}"
    mkdir -p "$iter"

    # Merge DWI volumes
    ap_out="$iter/ap.nii.gz"; pa_out="$iter/pa.nii.gz"
    if ! fslreorient2std "$ap" "$ap_out"; then echo "$SUBJ/$iter" >> "$WARN_LOG"; fi
    fslorient -copyqform2sform "$ap_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    fslorient -copysform2qform "$ap_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    if ! fslreorient2std "$pa" "$pa_out"; then echo "$SUBJ/$iter" >> "$WARN_LOG"; fi
    fslorient -copyqform2sform "$pa_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    fslorient -copysform2qform "$pa_out" || echo "$SUBJ/$iter" >> "$WARN_LOG"
    fslmerge -t "$iter/dwi.nii.gz" "$ap_out" "$pa_out"
    rm -f "$ap_out" "$pa_out"

    # bval/bvec
    base_ap=${ap##*/}; base_ap=${base_ap%.nii.gz}; base_ap=${base_ap%.nii}
    base_pa=${pa##*/}; base_pa=${base_pa%.nii.gz}; base_pa=${base_pa%.nii}
    [ -f "dwi_ap/${base_ap}.bval" ] && [ -f "dwi_pa/${base_pa}.bval" ] && \
      echo "$(cat dwi_ap/${base_ap}.bval) $(cat dwi_pa/${base_pa}.bval)" > "$iter/dwi.bval"
    [ -f "dwi_ap/${base_ap}.bvec" ] && [ -f "dwi_pa/${base_pa}.bvec" ] && \
      pr -mts' ' "dwi_ap/${base_ap}.bvec" "dwi_pa/${base_pa}.bvec" > "$iter/dwi.bvec"

    # Fieldmap selection and merge
    ts=${base_ap##*_}; ts=${ts%_*}
    fm_ap=(fieldmap_dwi_ap/*_${ts}_*.nii fieldmap_dwi_ap/*_${ts}_*.nii.gz)
    fm_pa=(fieldmap_dwi_pa/*_${ts}_*.nii fieldmap_dwi_pa/*_${ts}_*.nii.gz)
    best_ap=""; best_pa=""
    [ ${#fm_ap[@]} -gt 0 ] && best_ap=$(pick_best_b0 "$mask" "${fm_ap[@]}")
    [ ${#fm_pa[@]} -gt 0 ] && best_pa=$(pick_best_b0 "$mask" "${fm_pa[@]}")
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

# Cleanup mask
rm -f "$mask"
echo "Done: $cnt iterations for $SUBJ."
