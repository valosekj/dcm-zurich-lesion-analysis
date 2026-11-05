# DCM Zurich — Lesion Analysis

Lesion analysis pipelines for DCM patients, run per subject/session with `sct_run_batch`.

| Script | Image | Steps |
|--------|-------|-------|
| `lesion_analysis_ax.sh` | T2w axial | PAM50 registration (C3 and C5 disc labels, `-ref subject`) → atlas warping → atlas-based `sct_analyze_lesion` |
| `lesion_analysis_sag.sh` | T2w sagittal | SC + lesion segmentation → disc labeling → `sct_analyze_lesion` (length, width, midsagittal tissue bridges) |

Manual files from `derivatives/labels` are reused when present:

| File suffix | Axial | Sagittal |
|-------------|-------|----------|
| `_label-SC_seg` | required | otherwise SCIsegV2 (`sct_deepseg lesion_sci_t2`) |
| `_label-lesion` | otherwise SCIsegV2 | otherwise SCIsegV2 |
| `_labels-manual` (discs) | required | otherwise TotalSpineSeg (`sct_deepseg spine`) |

## Prerequisites

- [Spinal Cord Toolbox (SCT)](https://spinalcordtoolbox.com) v7.0 or higher
- GPU recommended for SCIsegV2 and TotalSpineSeg

## Usage

```bash
sct_run_batch -config config_lesion_analysis_ax.json
sct_run_batch -config config_lesion_analysis_sag.json
```

Edit `path_data` and `path_output` in the config files before running.

## Outputs

```
qc/            # QC reports (open qc/index.html); QCs are named by -qc-subject (e.g., sc_ax, lesion_sag, discs_manual)
qc_lesion/     # axial script only: lesion and warped atlas QCs
results/       # <lesion_file>_analysis.xlsx per subject/session
log/           # per-subject logs; *_segmentation.log and *_disc_labels.log record manual vs. automatic sources
```
