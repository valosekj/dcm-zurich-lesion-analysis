#!/usr/bin/env bash
#
# Atlas-based lesion analysis.
#
# The script performs the following steps:
#   1. Register the PAM50 template to T2w axial using all available disc labels (i.e., >2 labels registration)
#   2. Warp the white matter atlas to T2w axial space
#   3. Compute atlas-based lesion metrics from the T2w axial lesion segmentation
#
# NOTE: This script requires SCT v7.0 or higher.
#
# Usage:
#     sct_run_batch -config config_lesion_analysis.json
#
# Example of config_lesion_analysis.json:
# {
#   "path_data"   : "<PATH_TO_DATASET>",
#   "path_output" : "<PATH_TO_OUTPUT>",
#   "script"      : "<PATH_TO_REPO>/dcm-zurich-lesion-analysis/lesion_analysis.sh",
#   "jobs"        : 8
# }
#
# The following global variables are retrieved from the caller sct_run_batch
# but could be overwritten by uncommenting the lines below:
# PATH_DATA_PROCESSED="~/data_processed"
# PATH_RESULTS="~/results"
# PATH_LOG="~/log"
# PATH_QC="~/qc"
#
# Author: Jan Valosek
#

# Uncomment for full verbose
set -x

# Immediately exit if error
#set -e -o pipefail

# Exit if user presses CTRL+C (Linux) or CMD+C (OSX)
trap "echo Caught Keyboard Interrupt within script. Exiting now.; exit" INT

# Print retrieved variables from the sct_run_batch script to the log (to allow easier debug)
echo "Retrieved variables from the caller sct_run_batch:"
echo "PATH_DATA: ${PATH_DATA}"
echo "PATH_DATA_PROCESSED: ${PATH_DATA_PROCESSED}"
echo "PATH_RESULTS: ${PATH_RESULTS}"
echo "PATH_LOG: ${PATH_LOG}"
echo "PATH_QC: ${PATH_QC}"

SUBJECT=$1

# ------------------------------------------------------------------------------
# SCRIPT STARTS HERE
# ------------------------------------------------------------------------------
# get starting time:
start=`date +%s`

# Display useful info for the log, such as SCT version, RAM and CPU cores available
sct_check_dependencies -short

# Go to folder where data will be copied and processed
cd ${PATH_DATA_PROCESSED}

# Copy source T2w axial image
# Note: we use '/./' in order to include the sub-folder 'ses-M0'
rsync -Ravzh "${PATH_DATA}/./${SUBJECT}/anat/${SUBJECT//[\/]/_}_acq-axial_T2w.nii.gz" .

# Go to subject folder
cd "${SUBJECT}/anat"

# We do a substitution '/' --> '_' in case there is a subfolder 'ses-M0/'
file_t2_ax="${SUBJECT//[\/]/_}_acq-axial_T2w"
file_t2_ax_seg="${SUBJECT//[\/]/_}_acq-axial_T2w_label-SC_seg"
file_t2_ax_discs="${SUBJECT//[\/]/_}_acq-axial_T2w_labels-manual"
file_t2_ax_lesion="${SUBJECT//[\/]/_}_acq-axial_T2w_label-lesion"

# Check if source T2w axial exists
if [[ ! -e "${file_t2_ax}.nii.gz" ]]; then
    echo "File ${file_t2_ax}.nii.gz does not exist" >> "${PATH_LOG}/missing_files.log"
    echo "ERROR: File ${file_t2_ax}.nii.gz does not exist. Exiting."
    exit 1
fi

# Copy manual SC segmentation, disc labels, and lesion segmentation from derivatives/labels
rsync -avzh "${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_t2_ax_seg}.nii.gz" .
rsync -avzh "${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_t2_ax_discs}.nii.gz" .
rsync -avzh "${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_t2_ax_lesion}.nii.gz" .

# Check that all required manual files are present
for f in "${file_t2_ax_seg}.nii.gz" "${file_t2_ax_discs}.nii.gz" "${file_t2_ax_lesion}.nii.gz"; do
    if [[ ! -e "$f" ]]; then
        echo "File $f does not exist" >> "${PATH_LOG}/missing_files.log"
        echo "ERROR: File $f does not exist. Exiting."
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Axial lesion QC so we can see the lesion and compare it to the warped atlas
# ------------------------------------------------------------------------------
sct_qc -i "${file_t2_ax}.nii.gz" -s "${file_t2_ax_seg}.nii.gz" -d "${file_t2_ax_lesion}.nii.gz" -p sct_deepseg_lesion -plane axial -qc "${PATH_QC}" -qc-subject "lesion"

# ------------------------------------------------------------------------------
# Axial spinal cord QC
# ------------------------------------------------------------------------------
sct_qc -i "${file_t2_ax}.nii.gz" -s "${file_t2_ax_seg}.nii.gz" -p sct_deepseg_sc -plane axial -qc "${PATH_QC}" -qc-subject "spinal_cord"

# ------------------------------------------------------------------------------
# Keep only the C3 and C7 disc labels for registration to PAM50 template as
# -ref subject is only compatible with 1 or 2 landmarks labels
# Details: https://docs.google.com/presentation/d/1QOtSp75yDt19VFF4k3vksUA28yUMWqfkcBnsnMuNkek/edit?slide=id.p66#slide=id.p66
# ------------------------------------------------------------------------------
sct_label_utils -i "${file_t2_ax_discs}.nii.gz" -display

sct_label_utils -i "${file_t2_ax_discs}.nii.gz" -keep 3,7 -o "${file_t2_ax_discs}_C3C7.nii.gz"
sct_label_utils -i "${file_t2_ax_discs}_C3C7.nii.gz" -display

# ------------------------------------------------------------------------------
# Register the PAM50 template to T2w axial
# ------------------------------------------------------------------------------
sct_register_to_template \
  -i "${file_t2_ax}.nii.gz" \
  -s "${file_t2_ax_seg}.nii.gz" \
  -ldisc "${file_t2_ax_discs}_C3C7.nii.gz" \
  -ref subject \
  -param step=1,type=seg,algo=centermassrot,iter=10:step=2,type=seg,algo=bsplinesyn,slicewise=1,iter=10 \
  -c t2 \
  -ofolder t2w_ax_reg \
  -qc "${PATH_QC}" -qc-subject "${SUBJECT}"

# ------------------------------------------------------------------------------
# Warp atlas with white matter tracts
# ------------------------------------------------------------------------------
sct_warp_template \
  -d "${file_t2_ax}.nii.gz" \
  -w t2w_ax_reg/warp_template2anat.nii.gz \
  -ofolder t2w_ax_reg \
  -qc "${PATH_QC}" -qc-subject "${SUBJECT}"

# Generate QC report to assess warped PAM50 levels
sct_qc -i "${file_t2_ax}.nii.gz" -s t2w_ax_reg/template/PAM50_levels.nii.gz -p sct_label_vertebrae -qc "${PATH_QC}" -qc-subject "${SUBJECT}"

# ------------------------------------------------------------------------------
# Compute atlas-based lesion metrics
# ------------------------------------------------------------------------------
status=0
sct_analyze_lesion -m "${file_t2_ax_lesion}.nii.gz" -s "${file_t2_ax_seg}.nii.gz" -f t2w_ax_reg || status=$?

if [ $status -ne 0 ]; then
    echo "❌ sct_analyze_lesion failed for ${SUBJECT}" >> "${PATH_LOG}/sct_analyze_lesion.log"
    exit 0
else
    # Output: <lesion_file>_analysis.xlsx
    cp "${file_t2_ax_lesion}_analysis.xlsx" "${PATH_RESULTS}/${file_t2_ax_lesion}_analysis.xlsx"
    echo "✅ ${file_t2_ax_lesion}_analysis.xlsx created" >> "${PATH_LOG}/sct_analyze_lesion.log"
fi


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
end=`date +%s`
runtime=$((end-start))
echo
echo "~~~"
echo "SCT version: `sct_version`"
echo "Ran on:      `uname -nsr`"
echo "Duration:    $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
