#!/usr/bin/env bash
#
# Lesion analysis on T2w sagittal images.
#
# The script performs the following steps:
#   1. Spinal cord and lesion segmentation: manual segmentations from derivatives/labels are reused if present;
#      otherwise, SCIsegV2 (sct_deepseg lesion_sci_t2) is used to segment the spinal cord together with the lesion
#   2. Disc labeling: manual disc labels from derivatives/labels are reused if present; otherwise, TotalSpineSeg
#      (sct_deepseg spine) is used
#   3. Compute lesion metrics (length, width, midsagittal tissue bridges) using sct_analyze_lesion
#
# Expected filenames under derivatives/labels/<SUBJECT>/anat/ (same suffixes as for the axial T2w):
#   <SUBJECT>_acq-sagittal_T2w_label-SC_seg.nii.gz      spinal cord segmentation
#   <SUBJECT>_acq-sagittal_T2w_label-lesion.nii.gz      lesion segmentation
#   <SUBJECT>_acq-sagittal_T2w_labels-manual.nii.gz     disc labels
#
# NOTE: This script requires SCT v7.0 or higher.
# NOTE: SCIsegV2 and TotalSpineSeg are meant to run on GPU (see `CUDA_VISIBLE_DEVICES=X SCT_USE_GPU=X sct_deepseg ...` below).
#
# Usage:
#     sct_run_batch -config config_lesion_analysis_sag.json
#
# Example of config_lesion_analysis_sag.json:
# {
#   "path_data"   : "<PATH_TO_DATASET>",
#   "path_output" : "<PATH_TO_OUTPUT>",
#   "script"      : "<PATH_TO_REPO>/dcm-zurich-lesion-analysis/lesion_analysis_sag.sh",
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
# FUNCTIONS
# ------------------------------------------------------------------------------

# Reuse manual spinal cord and lesion segmentations from derivatives/labels if present.
# If either of them is missing, run SCIsegV2, which segments both the spinal cord and the lesion.
# A manual segmentation always takes precedence over the SCIsegV2 output (e.g., if only the manual SC seg
# exists, the manual SC seg is used together with the SCIsegV2 lesion).
# Sets the global variables FILESEG and FILELESION (without extension).
segment_cord_and_lesion_if_does_not_exist(){
  local file="$1"
  local file_seg_manual="$2"
  local file_lesion_manual="$3"
  local FILESEGMANUAL="${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_seg_manual}.nii.gz"
  local FILELESIONMANUAL="${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_lesion_manual}.nii.gz"
  echo "Looking for manual SC segmentation: ${FILESEGMANUAL}"
  echo "Looking for manual lesion segmentation: ${FILELESIONMANUAL}"

  # Run SCIsegV2 if any of the manual segmentations is missing
  if [[ ! -e ${FILESEGMANUAL} || ! -e ${FILELESIONMANUAL} ]]; then
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] Manual SC and/or lesion segmentation missing --> running SCIsegV2."
    CUDA_VISIBLE_DEVICES=0 SCT_USE_GPU=1 sct_deepseg lesion_sci_t2 -i "${file}.nii.gz"
    # SCIsegV2 outputs: ${file}_sc_seg.nii.gz and ${file}_lesion_seg.nii.gz
  fi

  # Spinal cord
  if [[ -e ${FILESEGMANUAL} ]]; then
    echo "✏️ [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: using manual SC segmentation" >> "${PATH_LOG}/T2w_sag_segmentation.log"
    rsync -avzh --no-g "${FILESEGMANUAL}" "${file_seg_manual}.nii.gz"
    FILESEG="${file_seg_manual}"
  else
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: using SCIsegV2 SC segmentation (manual missing)" >> "${PATH_LOG}/T2w_sag_segmentation.log"
    FILESEG="${file}_sc_seg"
  fi

  # Lesion
  if [[ -e ${FILELESIONMANUAL} ]]; then
    echo "✏️ [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: using manual lesion segmentation" >> "${PATH_LOG}/T2w_sag_segmentation.log"
    rsync -avzh --no-g "${FILELESIONMANUAL}" "${file_lesion_manual}.nii.gz"
    FILELESION="${file_lesion_manual}"
  else
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: using SCIsegV2 lesion segmentation (manual missing)" >> "${PATH_LOG}/T2w_sag_segmentation.log"
    FILELESION="${file}_lesion_seg"
  fi
}

# Reuse manual disc labels from derivatives/labels if present. Otherwise, run TotalSpineSeg.
# Sets the global variables FILELABEL (without extension) and QCDISCS (-qc-subject for the disc labels QC).
label_if_does_not_exist(){
  local file="$1"
  local file_discs_manual="$2"
  local FILELABELMANUAL="${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${file_discs_manual}.nii.gz"
  echo "Looking for manual disc labels: ${FILELABELMANUAL}"
  if [[ -e ${FILELABELMANUAL} ]]; then
    echo "✏️ [$(date '+%Y-%m-%d %H:%M:%S')] Manual disc labels found --> using manual."
    echo "✏️ [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: using manual disc labels" >> "${PATH_LOG}/T2w_sag_disc_labels.log"
    rsync -avzh --no-g "${FILELABELMANUAL}" "${file_discs_manual}.nii.gz"
    FILELABEL="${file_discs_manual}"
    QCDISCS="discs_manual"
  else
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] Manual disc labels missing --> running TotalSpineSeg."
    echo "🤖 [$(date '+%Y-%m-%d %H:%M:%S')] ${SUBJECT}: running TotalSpineSeg (manual disc labels missing)" >> "${PATH_LOG}/T2w_sag_disc_labels.log"
    CUDA_VISIBLE_DEVICES=0 SCT_USE_GPU=1 sct_deepseg spine -i "${file}.nii.gz" -label-vert 0 -qc "${PATH_QC}" -qc-subject "totalspineseg"
    # TotalSpineSeg disc labels output: ${file}_totalspineseg_discs.nii.gz
    FILELABEL="${file}_totalspineseg_discs"
    QCDISCS="discs_totalspineseg"
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

# Copy source T2w sagittal image
# Note: we use '/./' in order to include the sub-folder 'ses-M0'
rsync -Ravzh "${PATH_DATA}/./${SUBJECT}/anat/${SUBJECT//[\/]/_}_acq-sagittal_T2w.nii.gz" .

# Go to subject folder
cd "${SUBJECT}/anat"

# We do a substitution '/' --> '_' in case there is a subfolder 'ses-M0/'
file_t2_sag="${SUBJECT//[\/]/_}_acq-sagittal_T2w"
file_t2_sag_seg="${SUBJECT//[\/]/_}_acq-sagittal_T2w_label-SC_seg"
file_t2_sag_discs="${SUBJECT//[\/]/_}_acq-sagittal_T2w_labels-manual"
file_t2_sag_lesion="${SUBJECT//[\/]/_}_acq-sagittal_T2w_label-lesion"

# Check if source T2w sagittal exists
if [[ ! -e "${file_t2_sag}.nii.gz" ]]; then
    echo "File ${file_t2_sag}.nii.gz does not exist" >> "${PATH_LOG}/missing_files.log"
    echo "ERROR: File ${file_t2_sag}.nii.gz does not exist. Exiting."
    exit 1
fi

# ------------------------------------------------------------------------------
# Spinal cord and lesion segmentation (reuse manual; fall back to SCIsegV2)
# ------------------------------------------------------------------------------
segment_cord_and_lesion_if_does_not_exist "${file_t2_sag}" "${file_t2_sag_seg}" "${file_t2_sag_lesion}"
file_t2_sag_seg="${FILESEG}"
file_t2_sag_lesion="${FILELESION}"

# Spinal cord and lesion QCs (for both manual and SCIsegV2 segmentations), in both axial and sagittal planes.
# Note: the subject ID is kept in the QC report (it is parsed from the filename); -qc-subject is used to
# distinguish between the individual QCs.
# Note: `sct_qc -p sct_deepseg_sc` supports only the axial plane; the sagittal view of the spinal cord
# is provided by the "lesion_sag" QC (`-p sct_deepseg_lesion -plane sagittal`), which overlays both the cord and the lesion.
sct_qc -i "${file_t2_sag}.nii.gz" -s "${file_t2_sag_seg}.nii.gz" -p sct_deepseg_sc -qc "${PATH_QC}" -qc-subject "sc_ax"
sct_qc -i "${file_t2_sag}.nii.gz" -s "${file_t2_sag_seg}.nii.gz" -d "${file_t2_sag_lesion}.nii.gz" -p sct_deepseg_lesion -plane axial -qc "${PATH_QC}" -qc-subject "lesion_ax"
sct_qc -i "${file_t2_sag}.nii.gz" -s "${file_t2_sag_seg}.nii.gz" -d "${file_t2_sag_lesion}.nii.gz" -p sct_deepseg_lesion -plane sagittal -qc "${PATH_QC}" -qc-subject "lesion_sag"

# ------------------------------------------------------------------------------
# Disc labeling (reuse manual; fall back to TotalSpineSeg)
# ------------------------------------------------------------------------------
label_if_does_not_exist "${file_t2_sag}" "${file_t2_sag_discs}"
file_t2_sag_discs="${FILELABEL}"

# Disc labels QC (for both manual and TotalSpineSeg disc labels)
sct_qc -i "${file_t2_sag}.nii.gz" -s "${file_t2_sag_discs}.nii.gz" -p sct_label_utils -qc "${PATH_QC}" -qc-subject "${QCDISCS}"

# ------------------------------------------------------------------------------
# Compute lesion metrics
# ------------------------------------------------------------------------------
status=0
sct_analyze_lesion -m "${file_t2_sag_lesion}.nii.gz" -s "${file_t2_sag_seg}.nii.gz" -perslice 1 -qc "${PATH_QC}" -qc-subject "lesion_analysis" || status=$?

if [ $status -ne 0 ]; then
    echo "❌ sct_analyze_lesion failed for ${SUBJECT}" >> "${PATH_LOG}/sct_analyze_lesion.log"
    exit 0
else
    # Output: <lesion_file>_analysis.xlsx
    cp "${file_t2_sag_lesion}_analysis.xlsx" "${PATH_RESULTS}/${file_t2_sag_lesion}_analysis.xlsx"
    echo "✅ ${file_t2_sag_lesion}_analysis.xlsx created" >> "${PATH_LOG}/sct_analyze_lesion.log"
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
