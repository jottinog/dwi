Necessary scripts to process diffusion-weighted imaging (dwi) data from El Sendero (https://clinicaltrials.gov/study/NCT05551650), accounting for multiple dwi runs (e.g., run1 and run2, 51 volumes each) acquired in the same phase-encoding direction (PA) and two b0s acquired separately in opposite phase-encoding directions (PA and AP). You can modify the script in accordance to your needs.

1. The first step of the script will first co-register run1 and run2 (FSL's **FLIRT** + rotate bvecs of run2 with Python), and concatenate the two b0s to run TOPUP later. If more than two dwi runs are found (e.g., because of motion), the script will create as many iterations possible. Because in this dataset run1 and run2 include slightly different shell schemes, iterations will always be between run1 and run2.

For example, if a subject moved in run1 and we subseuqently have run1a and run1b, possible combinations include: run1a and run2 or run1b and run2 ✅. It will never combine run1a and run1b ❌.

The script expects the following structure. Timestamp corresponds to YYYY/MM/DD/HH/MM/SS, typically contained within the header of the file after conversion with dcm2niix:

      sub-001/
        dwi_1/
          sub-001_timestamp.nii.gz
          sub-001_timestamp.bval
          sub-001_timestamp.bvec
        dwi_2/
          sub-001_timestamp.nii.gz
          sub-001_timestamp.bval
          sub-001_timestamp.bvec
        fieldmap_ap/
          sub-001_timestamp.nii.gz
        fieldmap_pa/
          sub-001_timestamp.nii.gz
  
The script will result in a *dwi_merged* folder inside each participant with as many iterations as possible (*iteration_1* if only run1 and run2 available). Files in the folder:

    sub-001/
      dwi_merged/
        iteration_1/
          dwi.nii.gz          # run1 and run2 diffusion 4D volumes
          fieldmap.nii.gz     # the two b0s (named fieldmaps because the MRI sequence has it named like that)
          dwi.bval            # concatenated bval from run1 and run2
          dwi.bvec            # concatenated, and rotated, bvecs from run1 and run2
        dwi_1/
        dwi_2/
        fieldmap_ap/
        fieldmap_pa/

4. The second step will round bvals (depending on the scanner brand, sometimes bvals of 0 appear as 0.001). Then, the script will (1) denoise the images (**dwidenoise** from MRtrix3, default), (2) run FSL's **TOPUP**, and (3) create acparams and index files and apply FSL's **EDDY** with outlier detection and replacement. You might want to check your scanning parameters to change these files accordingly in the script. Then, (4) a session file is created to run **EDDY_QUAD** for quality control. The session file tells EDDY_QUAD that 2 dwi sessions (run1 and run2) were conducted and thus head position could be slightly different from volume 51 to volume 52 (when run1 ends and run2 starts). In the last step, the script (5) corrects field inhomogeneities (MRtrix' **dwibiascorrect** ants).

After processing, we generate 4D volumes with different shell configurations that were most appropriate for each diffusion model. **No user input is needed**. The script automatically extracts the volumes corresponding to the desired shells and re-arranges new bval/bvec files as needed. The following is modeled:

  + FSL's **dtifit** (DTI model) was fitted on low-shell volumes containing b = 500 s/mm² and  b = 1000 s/mm². 
  + The SMT model (**fitmicrodt** from https://github.com/ekaden/smt) was fitted on high-shell volumes, including b = 1000 s/mm², b = 2000 s/mm², and b = 3000 s/mm² (subsampled, see below).

  NOTE: Because the b = 3000 s/mm² shell was heavily oversampled (59 of 102 volumes; ~57% of all diffusion directions), after processing and before fitting any diffusion model, we subsampled this shell to 30 directions, while retaining shells b = 1000 and b= 2000 s/mm² intact. The subsampling selected the first 30 b = 3000 s/mm² volumes, which were distributed across the full acquisition and thus covered the diffusion sphere.
    
  + The NODDI model (**AMICO**, https://github.com/daducci/AMICO) was fitted on b = 1000 s/mm² and b = 2000 s/mm².

The intermediate script (2.5) is just a batch runner for step 2. If output files generated during step 2 are found, it will proceed to the next subject.

The script will result in an *output* folder inside *subject/dwi_merged/iteration_X/*

3. The last script, leverages the **eddy_quad** step in the previous to gather all participants json files to collapse into one single csv file to ease assessments on motion, SNR, CNR and help guiding decisions on quality control. If one subject has more than 1 iteration, it will further facilitate selection of the best individual's iteration.
