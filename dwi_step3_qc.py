#!/usr/bin/env python3

import json
import csv
from pathlib import Path
from datetime import datetime

# ============================================================
# CONFIG
# ============================================================
BASE_DIR = Path("/Volumes/ExtremeSSD/MRI/elsendero/derivatives/diffusion/completed_new")
OUT_DIR  = BASE_DIR.parent / "qc_summaries"
OUT_DIR.mkdir(exist_ok=True)

DATESTR = datetime.now().strftime("%Y-%m-%d")
OUT_CSV = OUT_DIR / f"eddy_qc_summary_{DATESTR}.csv"

# ============================================================
# CSV HEADER
# ============================================================
FIELDS = [
    "subject",
    "iteration",
    "qc_mot_abs",
    "qc_mot_rel",
    "qc_outliers_tot",
    "qc_outliers_b500",
    "qc_outliers_b1000",
    "qc_outliers_b2000",
    "qc_outliers_b3000",
    "qc_snr_b0",
    "qc_cnr_b500",
    "qc_cnr_b1000",
    "qc_cnr_b2000",
    "qc_cnr_b5000",
    "qc_snr_std_b0",
    "qc_cnr_std_b500",
    "qc_cnr_std_b1000",
    "qc_cnr_std_b2000",
    "qc_cnr_std_b5000",
    "qc_vox_displ_std",
]

rows = []

# ============================================================
# WALK SUBJECTS / ITERATIONS
# ============================================================
for subj_dir in sorted(BASE_DIR.glob("sub_*")):
    subject = subj_dir.name
    dwi_root = subj_dir / "dwi_merged"

    if not dwi_root.exists():
        continue

    for iter_dir in sorted(dwi_root.glob("iteration_*")):
        iteration = iter_dir.name
        qc_json = iter_dir / "output" / "quad_qc" / "qc.json"

        if not qc_json.exists():
            continue

        try:
            with qc_json.open() as f:
                qc = json.load(f)
        except Exception as e:
            print(f"⚠️ Failed to read {qc_json}: {e}")
            continue

        out_b   = qc.get("qc_outliers_b", [None] * 4)
        cnr_avg = qc.get("qc_cnr_avg", [None] * 5)
        cnr_std = qc.get("qc_cnr_std", [None] * 5)

        rows.append({
            "subject": subject,
            "iteration": iteration,
            "qc_mot_abs": qc.get("qc_mot_abs"),
            "qc_mot_rel": qc.get("qc_mot_rel"),
            "qc_outliers_tot": qc.get("qc_outliers_tot"),
            "qc_outliers_b500":  out_b[0],
            "qc_outliers_b1000": out_b[1],
            "qc_outliers_b2000": out_b[2],
            "qc_outliers_b3000": out_b[3],
            "qc_snr_b0":        cnr_avg[0],
            "qc_cnr_b500":      cnr_avg[1],
            "qc_cnr_b1000":     cnr_avg[2],
            "qc_cnr_b2000":     cnr_avg[3],
            "qc_cnr_b5000":     cnr_avg[4],
            "qc_snr_std_b0":        cnr_std[0],
            "qc_cnr_std_b500":      cnr_std[1],
            "qc_cnr_std_b1000":     cnr_std[2],
            "qc_cnr_std_b2000":     cnr_std[3],
            "qc_cnr_std_b5000":     cnr_std[4],
            "qc_vox_displ_std": qc.get("qc_vox_displ_std"),
        })

# ============================================================
# WRITE CSV
# ============================================================
with OUT_CSV.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=FIELDS)
    writer.writeheader()
    writer.writerows(rows)

print(f"✅ Wrote {len(rows)} rows to {OUT_CSV}")
