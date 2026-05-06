#!/usr/bin/env bash
#
# Atlas-based lesion analysis.
#
# The script performs the following steps:
#   1. Register the PAM50 template to T2w axial using all available disc labels (i.e., >2 labels registration)
#   2. Warp the white matter atlas to T2w axial space
#   3. Compute atlas-based lesion metrics from the T2w axial lesion segmentation
#
# Prerequisites:
#   - Spinal Cord Toolbox (SCT): https://spinalcordtoolbox.com
#   - Manual files copied from derivatives/labels:
#       <sub>_<ses>_acq-axial_T2w_label-SC_seg.nii.gz   (spinal cord segmentation)
#       <sub>_<ses>_acq-axial_T2w_labels-manual.nii.gz  (disc labels)
#
# Usage:
#   bash lesion_analysis.sh <sub_ID> <ses_ID>
#
# Example:
#   bash lesion_analysis.sh sub-080 ses-M0
#
# Outputs:
#   - qc/                      QC reports (open qc/index.html to review)
#   - t2w_ax_reg/              T2w ax → template registration + warped atlas
#   - *_lesion_analysis.xlsx   Atlas-based lesion metrics (per white matter tract)
#
# Author: Jan Valosek
#

###########################
# Parse input arguments
###########################
if [ $# -ne 2 ]; then
    echo "Usage: $0 <sub_ID> <ses_ID>"
    echo "Example: $0 sub-080 ses-M0"
    exit 1
fi
sub_ID=$1
ses_ID=$2

###########################
# T2w sagittal
###########################
file_t2_sag=${sub_ID}_${ses_ID}_acq-sagittal_T2w

########
# Segment the lesion and spinal cord
########
# Note: `-largest 1` is used to keep only the largest connected component to filter out possible small false positive blobs
sct_deepseg lesion_sci_t2 -i ${file_t2_sag}.nii.gz -largest 1 -qc ./qc
# Output files are:
#   - ${file_t2_sag}_lesion_seg.nii.gz  # we can ignore this file as we segment lesions from T2w ax
#   - ${file_t2_sag}_sc_seg.nii.gz
# Generate sagittal spinal cord QC (because sct_deepseg generates only axial QC)
sct_qc -i ${file_t2_sag}.nii.gz -d ${file_t2_sag}_sc_seg.nii.gz -s ${file_t2_sag}_sc_seg.nii.gz -p sct_deepseg_lesion -plane sagittal -qc ./qc

########
# Manual mid-vertebrae C3 and C7 labeling
########
sct_label_utils -i ${file_t2_sag}.nii.gz -create-viewer 3,7 -o ${file_t2_sag}_mid_vert_c3c7.nii.gz

########
# Registration to the template -- 2 labels -- mid vertebrae C3 and C7
########
sct_register_to_template -i ${file_t2_sag}.nii.gz -s ${file_t2_sag}_sc_seg.nii.gz -l ${file_t2_sag}_mid_vert_c3c7.nii.gz -c t2 -ofolder t2_sag_mid_vert_c3c7 -qc ./qc
# Check the QC
open qc/index.html

###########################
# T2w axial
###########################
file_t2_ax=${sub_ID}_${ses_ID}_acq-axial_T2w
file_t2_ax_seg=${sub_ID}_${ses_ID}_acq-axial_T2w_label-SC_seg        # copied from derivatives/labels
file_t2_ax_discs=${sub_ID}_${ses_ID}_acq-axial_T2w_labels-manual     # copied from derivatives/labels

########
# Register the template directly to the T2w ax
########
sct_register_to_template -i ${file_t2_ax}.nii.gz -s ${file_t2_ax_seg}.nii.gz -ldisc ${file_t2_ax_discs}.nii.gz -ref subject -param step=1,type=seg,algo=centermassrot,iter=10:step=2,type=seg,algo=bsplinesyn,slicewise=1,iter=10 -c t2 -ofolder t2w_ax_reg -qc ./qc
# Check the QC
open qc/index.html

########
# Warp atlas with white matter tracts
########
sct_warp_template -d ${file_t2_ax}.nii.gz -w t2w_ax_reg/warp_template2anat.nii.gz -ofolder t2w_ax_reg -qc ./qc
# Check the QC
open qc/index.html
# Generate QC report to assess warped PAM50 levels
sct_qc -i ${file_t2_ax}.nii.gz -s t2w_ax_reg/template/PAM50_levels.nii.gz -p sct_label_vertebrae -qc ./qc -qc-subject "PAM50_levels_2_t2w_ax"
# Check the QC
open qc/index.html

########
# Compute atlas-based lesion metrics
########
sct_analyze_lesion -m ${file_t2_ax}_lesion_seg.nii.gz -s ${file_t2_ax_seg}.nii.gz -f t2w_ax_reg -qc ./qc