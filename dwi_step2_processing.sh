#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Environment / threads
# ============================================================
AMICO_PY="/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"

"$AMICO_PY" - <<'PY'
import amico, sys
print("AMICO OK", getattr(amico,"__version__",None), "->", sys.executable)
PY

NTHREADS=$(sysctl -n hw.logicalcpu)
export OMP_NUM_THREADS=$NTHREADS
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$NTHREADS
export MKL_NUM_THREADS=$NTHREADS
export OPENBLAS_NUM_THREADS=$NTHREADS

# ============================================================
# Args
# ============================================================
[ $# -eq 1 ] || { echo "Usage: $0 <subject_id>"; exit 1; }
SUBJECT_ID="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DWI_ROOT="$SCRIPT_DIR/$SUBJECT_ID/dwi_merged"

echo "🧠 Subject: $SUBJECT_ID"
echo "📁 Iterations in: $DWI_ROOT"

shopt -s nullglob
ITERATIONS=("$DWI_ROOT"/iteration_*)
shopt -u nullglob
[ ${#ITERATIONS[@]} -gt 0 ] || { echo "❌ No iterations found"; exit 1; }

for ITER_DIR in "${ITERATIONS[@]}"; do
  set -euo pipefail

  ITER="$(basename "$ITER_DIR")"
  OUTPUT="$ITER_DIR/output"

  echo
  echo "============================================================"
  echo "▶ $SUBJECT_ID / $ITER"
  echo "============================================================"

  # ------------------------------------------------------------
  # Inputs
  # ------------------------------------------------------------
  for f in dwi.nii.gz dwi.bval dwi.bvec fieldmap.nii.gz; do
    [ -f "$ITER_DIR/$f" ] || { echo "❌ Missing $f"; exit 1; }
  done

  # ------------------------------------------------------------
  # Preprocessing state
  # ------------------------------------------------------------
  if [ -d "$OUTPUT" ] && [ -f "$OUTPUT/dwi_debs-corr_mask.nii.gz" ]; then
    echo "⏩ Preprocessing completed — reusing output"
  else
    rm -rf "$OUTPUT"
    mkdir -p "$OUTPUT"
  fi

  DWI_CORR="$OUTPUT/dwi_deb-corr.nii.gz"
  MASK="$OUTPUT/dwi_debs-corr_mask.nii.gz"
  BVEC="$OUTPUT/dwi_posteddy.bvec"
  BVAL="$OUTPUT/dwi_posteddy.bval"
  IDXFILE="$OUTPUT/idx_subsample_b3000.txt"

  # ------------------------------------------------------------
  # Preprocessing (only if needed)
  # ------------------------------------------------------------
  if [ ! -f "$MASK" ]; then
   echo "▶ No output directory — starting preprocessing"
   echo "▶ PREPROCESSING STARTED"
    cd "$OUTPUT"

   echo "  • Rounding b-values"
   # NEW see it it fixes 104 bval in some subjects
   tr -d '\r' < "$ITER_DIR/dwi.bval" > dwi_unix.bval
   # END
    #awk '{for(i=1;i<=NF;i++) printf "%.0f ",$i; print ""}' \
     # "$ITER_DIR/dwi.bval" > dwi_rounded.bval
     # new
     awk '{
  for(i=1;i<=NF;i++){
    printf "%d%s", int($i+0.5), (i<NF?" ":"")
  }
  print ""
}' dwi_unix.bval > dwi_rounded.bval
# guardrail
nbval=$(wc -w < dwi_rounded.bval)
nbvec=$(awk 'NR==1{print NF}' "$ITER_DIR/dwi.bvec")

[ "$nbval" -eq "$nbvec" ] || {
  echo "❌ Gradient mismatch after rounding: bval=$nbval bvec=$nbvec"
  exit 1
}
#end

   echo "  • Convert DWI → MIF"
    mrconvert "$ITER_DIR/dwi.nii.gz" dwi.mif \
      -fslgrad "$ITER_DIR/dwi.bvec" dwi_rounded.bval -quiet

   echo "  • Denoising"
    dwidenoise dwi.mif dwi_dn.mif -nthreads "$NTHREADS" -quiet

   echo "  • Export denoised NIfTI"
    mrconvert dwi_dn.mif dwi_dn.nii.gz \
      -export_grad_fsl dwi_dn.bvec dwi_dn.bval -quiet
 
   echo "  • Preparing acqparams file"
    cat > acqparams.txt <<EOF
0 -1 0 0.0917507
0  1 0 0.0917507
EOF

   echo "  • Doing TOPUP"
    topup --imain="$ITER_DIR/fieldmap.nii.gz" \
          --datain=acqparams.txt \
          --config=b02b0.cnf \
          --out=topup \
          --iout=topup_unwarp \
          --fout=fieldmap_Hz \
          --nthr="$NTHREADS"

    fslmaths topup_unwarp -Tmean topup_unwarp_mean
    bet topup_unwarp_mean.nii.gz nodif -m -f 0.3

   echo "  • Creating index and session for EDDY" 
    NVOL=$(fslval dwi_dn.nii.gz dim4)
    awk -v n="$NVOL" 'BEGIN{for(i=1;i<=n;i++)print 2}' > index.txt
    awk 'BEGIN{for(i=1;i<=51;i++)print 1;for(i=1;i<=51;i++)print 2}' > session.txt

   echo "  • Running EDDY"
    eddy diffusion \
      --imain=dwi_dn.nii.gz \
      --mask=nodif_mask.nii.gz \
      --acqp=acqparams.txt \
      --index=index.txt \
      --session=session.txt \
      --bvecs=dwi_dn.bvec \
      --bvals=dwi_dn.bval \
      --topup=topup \
      --data_is_shelled \
      --repol \
      --cnr_maps \
      --nthr="$NTHREADS" \
      --out=dwi_eddy \
      > /dev/null 2>&1

    echo "  • Running EDDY quad (QC)"
    eddy_quad dwi_eddy \
      -idx index.txt \
      -par acqparams.txt \
      -m nodif_mask.nii.gz \
      -b dwi_dn.bval \
      -g dwi_eddy.eddy_rotated_bvecs \
      -f fieldmap_Hz.nii.gz \
      -o quad_qc \
      > /dev/null 2>&1

    mv dwi_eddy.eddy_rotated_bvecs "$BVEC"
    cp dwi_dn.bval "$BVAL"

    mrconvert dwi_eddy.nii.gz dwi_eddy.mif \
      -fslgrad "$BVEC" "$BVAL" -quiet

    dwibiascorrect ants dwi_eddy.mif dwi_bc.mif \
      -nthreads "$NTHREADS" -quiet

    mrconvert dwi_bc.mif "$DWI_CORR" -quiet

    fslroi "$DWI_CORR" tmp 0 1
    bet tmp dwi_debs-corr -m -f 0.3
    rm -f tmp.nii.gz
  fi

  # ------------------------------------------------------------
  # Subsample b=3000
  # ------------------------------------------------------------
  echo "  • Subsampling b=3000 for SMT"
  if [ ! -f "$IDXFILE" ]; then
    python3 - "$BVAL" "$IDXFILE" <<'PY'
import numpy as np, sys
b = np.loadtxt(sys.argv[1])
idx = np.where(np.isclose(b,3000))[0][:30]
keep = np.sort(np.concatenate([np.where(b!=3000)[0], idx]))
np.savetxt(sys.argv[2], keep.astype(int), fmt="%d")
PY
  fi

  IDXCSV=$(paste -sd, "$IDXFILE")

  # ============================================================
  # DTI
  # ============================================================
  cd "$OUTPUT"
  rm -rf FSL/dti && mkdir -p FSL/dti

  mrconvert "$DWI_CORR" dti_tmp.mif -fslgrad "$BVEC" "$BVAL" -quiet
  dwiextract dti_tmp.mif -shells 0,500,1000 dti.mif -quiet
  mrconvert dti.mif FSL/dti/dti.nii.gz \
    -export_grad_fsl FSL/dti/dti.bvec FSL/dti/dti.bval -quiet

  echo "  • Fitting DTI (b=0, b=500, b=1000)"
  dtifit --data=FSL/dti/dti.nii.gz \
         --out=FSL/dti/dti \
         --mask="$MASK" \
         --bvecs=FSL/dti/dti.bvec \
         --bvals=FSL/dti/dti.bval \
         --save_tensor \
         > /dev/null 2>&1

  cd FSL/dti
  KEEP=( dti_*.nii.gz dti.bval dti.bvec )
  for f in *; do [[ " ${KEEP[*]} " =~ " $f " ]] || rm -rf "$f"; done

  # ============================================================
  # AMICO / NODDI
  # ============================================================
  cd "$OUTPUT"
  rm -rf AMICO/tmp_noddi && mkdir -p AMICO/tmp_noddi
  cd AMICO/tmp_noddi

  mrconvert "$DWI_CORR" noddi_tmp.mif -fslgrad "$BVEC" "$BVAL" -quiet
  dwiextract noddi_tmp.mif -shells 0,1000,2000 noddi.mif -quiet
  mrconvert noddi.mif dwi_for_noddi.nii.gz \
    -export_grad_fsl noddi.bvec noddi.bval -quiet

  echo "  • Fitting NODDI (b=0, b=1000, b=2000)"
  export AMICO_MASK="$OUTPUT/dwi_debs-corr_mask.nii.gz"

  "$AMICO_PY" > /dev/null 2>&1 <<'PY'
import os, amico
amico.setup()
amico.util.fsl2scheme('noddi.bval','noddi.bvec')
ae = amico.Evaluation()
ae.set_model('NODDI')
ae.load_data(
    dwi_filename='dwi_for_noddi.nii.gz',
    scheme_filename='noddi.scheme',
    mask_filename=os.environ['AMICO_MASK'],
    b0_thr=0
)
ae.generate_kernels(regenerate=True)
ae.load_kernels()
ae.fit()
ae.save_results()
PY

  mkdir -p "$OUTPUT/AMICO/NODDI"
  mv AMICO/NODDI/*.nii.gz "$OUTPUT/AMICO/NODDI/"
  mv noddi.bvec noddi.bval "$OUTPUT/AMICO/NODDI/"
  cd "$OUTPUT"
  rm -rf AMICO/tmp_noddi

  # ============================================================
  # SMT
  # ============================================================
  rm -rf SMT && mkdir -p SMT

  mrconvert "$DWI_CORR" SMT/tmp.mif \
    -fslgrad "$BVEC" "$BVAL" \
    -coord 3 "$IDXCSV" -quiet

  dwiextract SMT/tmp.mif -shells 0,1000,2000,3000 SMT/smt.mif -quiet
  mrconvert SMT/smt.mif SMT/smt.nii.gz \
    -export_grad_fsl SMT/smt.bvec SMT/smt.bval -quiet

  dwiextract SMT/smt.mif -bzero SMT/b0.mif -quiet
  mrconvert SMT/b0.mif -coord 3 0 SMT/b0_1vol.mif -quiet
  mrconvert SMT/b0_1vol.mif SMT/b0.nii.gz -quiet
  bet SMT/b0.nii.gz SMT/bet -m -f 0.3

  mrconvert SMT/bet_mask.nii.gz SMT/mask_tmp.mif -quiet
  mrtransform SMT/mask_tmp.mif -template SMT/smt.mif -interp nearest SMT/mask.mif -quiet
  mrconvert SMT/mask.mif SMT/mask.nii.gz -quiet
  
  echo "  • Fitting SMT (b=0, b=1000, b=2000, b=3000)"
  fitmicrodt \
    --bvals SMT/smt.bval \
    --bvecs SMT/smt.bvec \
    --mask  SMT/mask.nii.gz \
    SMT/smt.nii.gz SMT/smt_{}.nii.gz \
    > /dev/null 2>&1

  cd SMT
  KEEP=( smt_*.nii.gz smt.bval smt.bvec )
  for f in *; do [[ " ${KEEP[*]} " =~ " $f " ]] || rm -rf "$f"; done

  # ============================================================
  # FINAL CLEANUP (OUTPUT)
  # ============================================================
  cd "$OUTPUT"
  echo "  • Cleaning things up"
  KEEP=( dwi_deb-corr.nii.gz dwi_debs-corr.nii.gz dwi_debs-corr_mask.nii.gz dwi_posteddy.bval dwi_posteddy.bvec idx_subsample_b3000.txt FSL AMICO SMT quad_qc )
  for f in *; do [[ " ${KEEP[*]} " =~ " $f " ]] || rm -rf "$f"; done

  echo "🎉 $SUBJECT_ID / $ITER DONE"

done

echo "✅ ALL ITERATIONS COMPLETED SUCCESSFULLY"
