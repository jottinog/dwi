Necessary scripts to process diffusion-weighted imaging (dwi) data from El Sendero (https://clinicaltrials.gov/study/NCT05551650), accounting for multiple dwi runs.
The first step of the script will first co-register (FSL's FLIRT + rotate bvecs with Python) all posible iterations between run1 and run2, and find the best looking non-diffusion-weighted opposite phase-encoding images (b0s) to run TOPUP later.
If one than two runs are found, the script will create as many iterations possible. Because run1 and run2 include different shells, iterations will always be between run1 and run2 (e.g., run1a and run2, run1b and run2 ✅ never run1a and run1b ❌)

The second step will denoise (dwidenoise from MRtrix3) the images with the default configuration. It then will run FSL's TOPUP, apply FSL's EDDY with outlier detection and replacement, and correct field inhomogeneities (MRtrix' dwibiascorrect ants).

NOTE: Because the b = 3000 s/mm² shell was heavily oversampled (59 of 102 volumes; ~57% of all diffusion directions), after processing and before fitting any diffusion model, we subsampled this shell to 30 directions, while retaining all lower-b shells. The subsampling selected the first 30 b = 3000 volumes, which were distributed across the full acquisition and thus covered the diffusion sphere.

After processing, we generate 4D volumes with different shell configurations that were most appropriate for each diffusion model. FSL's dtifit (DTI model) was fitted on volumes containing b = 500 and  b = 1000. The SMT model (fitmicrodt from https://github.com/ekaden/smt) was fitted on b = 1000, b = 2000, and b = 3000 (subsampled). The NODDI model (AMICO) was fitted on b = 1000 and b = 2000.

The intermediate script (2.5) is just a batch runner for step 2.

The last script, leverages the eddy_quad step in the previous to gather all participants json files to collapse into one single, dated csv file assessments on motion, SNR, CNR and guide the decision on quality control and selection of best individual's iteration (if this is the case).
