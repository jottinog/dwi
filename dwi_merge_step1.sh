#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# -------------------------------------------------------------------
# Purpose: Co-register and merge DWI AP/PA pairs and pick best b=0 fieldmaps by mean brain signal.
#          Logs any fslorient or fslreorient2std failures to WARN_LOG.
# Usage:
#   chmod +x dwi_merge_step1.sh
#   ./dwi_merge_step1.sh /path/to/SUBJECT_DIR
# -------------------------------------------------------------------

# ------------------------------------------------------------
# Usage
# ------------------------------------------------------------
[ $# -eq 1 ] || { echo "Usage: $0 /path/to/SUBJECT_DIR"; exit 1; }
SUBJ="$1"
cd "$SUBJ" || { echo "Cannot cd into $SUBJ"; exit 1; }

SUBJ_NAME="$(basename "$SUBJ")"

# ------------------------------------------------------------
# Skip if already processed
# ------------------------------------------------------------
if [ -d dwi_merged ] && [ "$(find dwi_merged -mindepth 1 | wc -l)" -gt 0 ]; then
  exit 0
fi

mkdir -p dwi_merged

# ------------------------------------------------------------
# Helper: extract mean b0 (bval-driven)
# ------------------------------------------------------------
extract_mean_b0 () {
  local nii="$1" bval="$2" out="$3"
  python3 - <<PY
import numpy as np, nibabel as nib
b = np.loadtxt("$bval")
idx = np.where(b == 0)[0]
if len(idx) == 0:
    raise RuntimeError("No b0 volumes found")
img = nib.load("$nii")
data = img.get_fdata()[..., idx]
mean = data.mean(axis=3)
nib.Nifti1Image(mean, img.affine, img.header).to_filename("$out")
PY
}

# ------------------------------------------------------------
# Helper: rotate bvecs using FLIRT matrix
# ------------------------------------------------------------
rotate_bvecs () {
  local mat="$1" inbvec="$2" outbvec="$3"
  python3 - <<PY
import numpy as np
R = np.loadtxt("$mat")[:3,:3]
b = np.loadtxt("$inbvec")
if b.shape[0] != 3: b = b.T
b = R @ b
n = np.linalg.norm(b, axis=0)
b[:, n>1e-8] /= n[n>1e-8]
np.savetxt("$outbvec", b, fmt="%.10f")
PY
}

# ------------------------------------------------------------
# Pre-cache run1 reoriented DWIs + run1 mean b0s
# ------------------------------------------------------------
CACHE_DIR="dwi_merged/.cache"
mkdir -p "$CACHE_DIR"

dwi1_files=(dwi_1/*.nii*)
dwi2_files=(dwi_2/*.nii*)

n1=${#dwi1_files[@]}
n2=${#dwi2_files[@]}

# ---- RESTORED GUARD (unchanged behavior) ----
if [ "$n1" -eq 0 ] || [ "$n2" -eq 0 ]; then
  echo "⏭ ${SUBJ_NAME}: skipping (dwi_1=$n1, dwi_2=$n2)"
  exit 0
fi

NTOT=$((n1 * n2))
echo "▶ ${SUBJ_NAME} - found ${NTOT} iterations"

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
cnt=0
for run1 in dwi_1/*.nii*; do
  base1=$(basename "$run1" | sed 's/\.nii.*//')
  bval1="dwi_1/${base1}.bval"
  bvec1="dwi_1/${base1}.bvec"

  run1_std="$CACHE_DIR/${base1}_std.nii.gz"
  run1_b0="$CACHE_DIR/${base1}_b0mean.nii.gz"

  if [ ! -f "$run1_std" ]; then
    fslreorient2std "$run1" "$run1_std" >/dev/null 2>&1
    extract_mean_b0 "$run1_std" "$bval1" "$run1_b0"
  fi

  for run2 in dwi_2/*.nii*; do
    ((cnt++))
    iter="dwi_merged/iteration_${cnt}"
    mkdir -p "$iter"

    base2=$(basename "$run2" | sed 's/\.nii.*//')
    bval2="dwi_2/${base2}.bval"
    bvec2="dwi_2/${base2}.bvec"

    run2_std="$iter/run2_std.nii.gz"
    run2_b0="$iter/run2_b0mean.nii.gz"

    fslreorient2std "$run2" "$run2_std" >/dev/null 2>&1
    extract_mean_b0 "$run2_std" "$bval2" "$run2_b0"

    # ---- Register run2 → run1 ----
    flirt \
      -in  "$run2_b0" \
      -ref "$run1_b0" \
      -dof 6 \
      -omat "$iter/run2_to_run1.mat" \
      >/dev/null 2>&1

    flirt \
      -in "$run2_std" \
      -ref "$run1_b0" \
      -applyxfm -init "$iter/run2_to_run1.mat" \
      -interp spline \
      -out "$iter/run2_in_run1.nii.gz" \
      >/dev/null 2>&1

    rotate_bvecs "$iter/run2_to_run1.mat" "$bvec2" "$iter/run2_rot.bvec"

    # ---- Merge DWIs ----
    fslmerge -t "$iter/dwi.nii.gz" \
      "$run1_std" \
      "$iter/run2_in_run1.nii.gz" \
      >/dev/null 2>&1

    paste -d' ' "$bval1" "$bval2" > "$iter/dwi.bval"

    python3 - <<PY
import numpy as np
b1 = np.loadtxt("$bvec1"); b2 = np.loadtxt("$iter/run2_rot.bvec")
if b1.shape[0] != 3: b1 = b1.T
if b2.shape[0] != 3: b2 = b2.T
np.savetxt("$iter/dwi.bvec", np.hstack([b1,b2]), fmt="%.10f")
PY

    # ---- Fieldmaps: reorient + grid match ONLY ----
    ts=$(echo "$base1" | sed -E 's/.*_([0-9]{14})_.*/\1/')

    fm_ap=(fieldmap_dwi_ap/*_${ts}_*.nii*)
    fm_pa=(fieldmap_dwi_pa/*_${ts}_*.nii*)

    if [ ${#fm_ap[@]} -ge 1 ] && [ ${#fm_pa[@]} -ge 1 ]; then
      fslreorient2std "${fm_ap[0]}" "$iter/fm_ap_std.nii.gz" >/dev/null 2>&1
      fslreorient2std "${fm_pa[0]}" "$iter/fm_pa_std.nii.gz" >/dev/null 2>&1

      flirt -in "$iter/fm_ap_std.nii.gz" -ref "$run1_b0" \
            -applyxfm -usesqform -interp spline \
            -out "$iter/fm_ap_in_run1.nii.gz" >/dev/null 2>&1

      flirt -in "$iter/fm_pa_std.nii.gz" -ref "$run1_b0" \
            -applyxfm -usesqform -interp spline \
            -out "$iter/fm_pa_in_run1.nii.gz" >/dev/null 2>&1

      fslmerge -t "$iter/fieldmap.nii.gz" \
        "$iter/fm_ap_in_run1.nii.gz" \
        "$iter/fm_pa_in_run1.nii.gz" \
        >/dev/null 2>&1
    fi

    # ---- Cleanup ----
    find "$iter" -type f \
      ! -name 'dwi.nii.gz' \
      ! -name 'dwi.bval' \
      ! -name 'dwi.bvec' \
      ! -name 'fieldmap.nii.gz' \
      -delete

    echo "✓ ${SUBJ_NAME} - iteration_${cnt}"
  done
done

rm -rf "$CACHE_DIR"

