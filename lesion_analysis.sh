#!/usr/bin/env bash
#
# Atlas-based lesion analysis.
#
# The script performs the following steps:
#   1. Register the PAM50 template to T2w axial using all available disc labels (i.e., >2 labels registration)
#   2. Warp the white matter atlas to T2w axial space
#   3. Compute atlas-based lesion metrics from the T2w axial lesion segmentation
#
# Manual spinal cord segmentation and disc labels are required (derivatives/labels). The manual lesion
# segmentation is reused if present; otherwise, the lesion is segmented using SCIsegV2. The spinal cord
# segmentation produced by SCIsegV2 is not used -- the manual one from derivatives/labels is used instead.
#
# NOTE: This script requires SCT v7.0 or higher.
# NOTE: The SCIsegV2 fallback is meant to run on GPU (see `CUDA_VISIBLE_DEVICES=X SCT_USE_GPU=X sct_deepseg ...` below).
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

# Separate QC for lesion and warped atlas
PATH_QC_LESION="${PATH_QC}_lesion"

SUBJECT=$1

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# Reuse manual lesion segmentation from derivatives/labels if present.
# Otherwise run SCIsegV2. Note that SCIsegV2 produces both ${file}_sc_seg and ${file}_lesion_seg;
# only the lesion is used -- the spinal cord segmentation is always taken from derivatives/labels.
# Sets the global variable FILELESION (without extension) to the lesion segmentation to use.
segment_lesion_if_does_not_exist(){
  local file="$1"
  local file_lesion_manual="$2"
  FILELESIONMANUAL="${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_lesion_manual}.nii.gz"
  echo "Looking for manual lesion segmentation: ${FILELESIONMANUAL}"
  if [[ -e ${FILELESIONMANUAL} ]]; then
    echo "✏️ [$(date '+%Y-%m-%d %H:%M:%S')] Manual lesion segmentation found --> using manual."
    echo "✏️ [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: using manual lesion segmentation" >> "${PATH_LOG}/T2w_segmentation.log"
    rsync -avzh --no-g "${FILELESIONMANUAL}" "${file_lesion_manual}.nii.gz"
    FILELESION="${file_lesion_manual}"
  else
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] Manual lesion segmentation missing --> running SCIsegV2."
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: running SCIsegV2 (manual lesion missing)" >> "${PATH_LOG}/T2w_segmentation.log"
    CUDA_VISIBLE_DEVICES=0 SCT_USE_GPU=1 sct_deepseg lesion_sci_t2 -i "${file}.nii.gz" -qc "${PATH_QC_LESION}" -qc-subject "${SUBJECT}"
    # SCIsegV2 outputs: ${file}_sc_seg.nii.gz (not used) and ${file}_lesion_seg.nii.gz
    FILELESION="${file}_lesion_seg"
  fi
}

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

# Copy manual SC segmentation and disc labels from derivatives/labels
rsync -avzh "${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_t2_ax_seg}.nii.gz" .
rsync -avzh "${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_t2_ax_discs}.nii.gz" .

# Check that all required manual files are present
for f in "${file_t2_ax_seg}.nii.gz" "${file_t2_ax_discs}.nii.gz"; do
    if [[ ! -e "$f" ]]; then
        echo "File $f does not exist" >> "${PATH_LOG}/missing_files.log"
        echo "ERROR: File $f does not exist. Exiting."
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Lesion segmentation (reuse manual; fall back to SCIsegV2)
# ------------------------------------------------------------------------------
segment_lesion_if_does_not_exist "${file_t2_ax}" "${file_t2_ax_lesion}"
file_t2_ax_lesion="${FILELESION}"

# ------------------------------------------------------------------------------
# Axial lesion QC so we can see the lesion and compare it to the warped atlas
# ------------------------------------------------------------------------------
sct_qc -i "${file_t2_ax}.nii.gz" -s "${file_t2_ax_seg}.nii.gz" -d "${file_t2_ax_lesion}.nii.gz" -p sct_deepseg_lesion -plane axial -qc "${PATH_QC_LESION}" -qc-subject "lesion"

# ------------------------------------------------------------------------------
# Axial spinal cord QC
# ------------------------------------------------------------------------------
sct_qc -i "${file_t2_ax}.nii.gz" -s "${file_t2_ax_seg}.nii.gz" -p sct_deepseg_sc -plane axial -qc "${PATH_QC}" -qc-subject "spinal_cord"

# ------------------------------------------------------------------------------
# Keep only the C3 and C5 disc label for registration to PAM50 template as
# -ref subject is only compatible with 1 or 2 landmarks labels
# Details: https://docs.google.com/presentation/d/1QOtSp75yDt19VFF4k3vksUA28yUMWqfkcBnsnMuNkek/edit?slide=id.p66#slide=id.p66
# ------------------------------------------------------------------------------
sct_label_utils -i "${file_t2_ax_discs}.nii.gz" -display

sct_label_utils -i "${file_t2_ax_discs}.nii.gz" -keep 3,5 -o "${file_t2_ax_discs}_C3C5.nii.gz"
sct_label_utils -i "${file_t2_ax_discs}_C3C5.nii.gz" -display

# Sagittal disc labels QCs
sct_qc -i "${file_t2_ax}.nii.gz" -s "${file_t2_ax_discs}.nii.gz" -p sct_label_utils -qc "${PATH_QC}" -qc-subject "discs_all"
sct_qc -i "${file_t2_ax}.nii.gz" -s "${file_t2_ax_discs}_C3C5.nii.gz" -p sct_label_utils -qc "${PATH_QC}" -qc-subject "discs_C3C5"

# ------------------------------------------------------------------------------
# Register the PAM50 template to T2w axial
# ------------------------------------------------------------------------------
sct_register_to_template \
  -i "${file_t2_ax}.nii.gz" \
  -s "${file_t2_ax_seg}.nii.gz" \
  -ldisc "${file_t2_ax_discs}_C3C5.nii.gz" \
  -ref subject \
  -param step=1,type=seg,algo=centermassrot,iter=10:step=2,type=seg,algo=syn,slicewise=1,iter=15,smooth=1 \
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
  -qc "${PATH_QC_LESION}" -qc-subject "warped_atlas"

# Generate QC report to assess warped PAM50 levels
sct_qc -i "${file_t2_ax}.nii.gz" -s t2w_ax_reg/template/PAM50_levels.nii.gz -p sct_label_vertebrae -qc "${PATH_QC}" -qc-subject "PAM50_levels_in_native_space"

# ------------------------------------------------------------------------------
# Compute atlas-based lesion metrics
# ------------------------------------------------------------------------------
status=0
sct_analyze_lesion -m "${file_t2_ax_lesion}.nii.gz" -s "${file_t2_ax_seg}.nii.gz" -f t2w_ax_reg -perslice 1 || status=$?

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
