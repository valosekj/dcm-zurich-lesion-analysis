# DCM Zurich — Lesion Analysis

Atlas-based lesion analysis pipeline for DCM patients. 
The pipeline registers the PAM50 template to the T2w axial image using disc labels and computes atlas-based lesion metrics.

## Prerequisites

- [Spinal Cord Toolbox (SCT)](https://spinalcordtoolbox.com) installed and on `PATH`
- Manual files copied from `derivatives/labels` into the working directory:
  - `<sub>_<ses>_acq-axial_T2w_label-SC_seg.nii.gz` — SC segmentation
  - `<sub>_<ses>_acq-axial_T2w_labels-manual.nii.gz` — disc labels

## Usage

Run the pipeline from the subject's session directory (where the NIfTI files live):

```bash
bash /path/to/lesion_analysis.sh <sub_ID> <ses_ID>
```

**Example:**

```bash
bash lesion_analysis.sh sub-080 ses-M0
```

## Pipeline Steps

| Step | Input | Command | Output |
|------|-------|---------|--------|
| 1. Template registration to T2w ax (>2 disc labels) | SC seg + disc labels | `sct_register_to_template` | `t2w_ax_reg/` |
| 2. Atlas warping (T2w ax) | Warp from step 1 | `sct_warp_template` | `t2w_ax_reg/template/` |
| 3. Lesion metrics | Lesion seg + warped atlas | `sct_analyze_lesion` | `*_lesion_analysis.xlsx` |

## Outputs

```
qc/                          # QC reports — open qc/index.html to review
t2w_ax_reg/                  # T2w ax → template registration + warped atlas
*_lesion_analysis.xlsx        # Atlas-based lesion metrics (per white matter tract)
```

## Notes

- QC reports are generated after each major step; review `qc/index.html` to verify registration quality before proceeding.