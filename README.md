Necessary scripts to process diffusion-weighted imaging (dwi) data from El Sendero (https://clinicaltrials.gov/study/NCT05551650), accounting for multiple dwi runs (run1 and run2, 51 volumes each and same phase-encoding direction: PA)

1. The first step of the script will first co-register (FSL's **FLIRT** + rotate bvecs with Python) run1 and run2, and concatenate the two b0s (acquired separately in AP and PA phase-encoding direction) to run TOPUP later. If more than two dwi runs are found (e.g., because of motion), the script will create as many iterations possible. Please note that, because run1 and run2 include slightly different shell schemes, iterations will always be between run1 and run2 (e.g., run1a and run2, run1b and run2 ✅ but never run1a and run1b ❌).
  
The script will result in a *dwi_merged* folder inside each participant with as many iterations as possible (*iteration_1* if only run1 and run2 available).

4. The second step will denoise (**dwidenoise** from MRtrix3, default) the images. It then will run FSL's **TOPUP**, apply FSL's **EDDY** with outlier detection and replacement. This step include the generation of an index file to indicate EDDY that 2 runs were conducted and head position could be slightly different from volume 51 to volume 52. Lastly, it corrects field inhomogeneities (MRtrix' **dwibiascorrect** ants).

After processing, we generate 4D volumes with different shell configurations that were most appropriate for each diffusion model:

  + FSL's **dtifit** (DTI model) was fitted on volumes containing b = 500 and  b = 1000. 
  + The SMT model (**fitmicrodt** from https://github.com/ekaden/smt) was fitted on b = 1000, b = 2000, and b = 3000 (subsampled, see note below).
    
  NOTE: Because the b = 3000 s/mm² shell was heavily oversampled (59 of 102 volumes; ~57% of all diffusion directions), after processing and before fitting any diffusion model, we subsampled this shell to 30 directions, while retaining all lower-b shells. The subsampling selected the first 30 b = 3000 volumes, which were distributed across the full acquisition and thus covered the diffusion sphere.
    
  + The NODDI model (**AMICO**, https://github.com/daducci/AMICO) was fitted on b = 1000 and b = 2000.

The intermediate script (2.5) is just a batch runner for step 2. If output files generated during step 2 are found, it will proceed to the next subject.

The script will result in an *output* folder inside *dwi/merged/iteration_X/*

3. The last script, leverages the **eddy_quad** step in the previous to gather all participants json files to collapse into one single csv file to ease assessments on motion, SNR, CNR and help guiding decisions on quality control. If one subject has more than 1 iteration, it will further facilitate selection of the best individual's iteration.
