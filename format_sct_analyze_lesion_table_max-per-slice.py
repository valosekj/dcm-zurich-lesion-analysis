"""
Script to format XLSX files produced by `sct_analyze_lesion -perslice 1` (i.e., one row per slice) for
multiple subjects and summarize them into a single XLSX table (one row per subject).

For each subject XLSX, the per-slice data from the "ROI_occupied_by_lesion" sheet is processed for the
left (PAM50_12) and right (PAM50_13) spinal lemniscus separately, as follows:
    1. Within each vertebral level, take the max across that level's slices.
    2. Across vertebral levels, take the max of those per-level maxima.
The left and right sides are handled independently, so their maxima may occur at different slices (and different
vertebral levels).

Input: a directory containing per-subject XLSX files named like (output of `sct_analyze_lesion` run using
`sct_run_batch`):
    sub-XXX_ses-YYY_acq-axial_T2w_label-lesion_analysis.xlsx

Sample output table (one row per subject):
        Subject   Session   Left spinal lemniscus [%]   Left level   Right spinal lemniscus [%]   Right level
        sub-001   ses-M0    36.20                       C4           18.90                        C5
        sub-008   ses-M0    0.00                                     31.28                        C4
        ...

Usage:
    source ${SCT_DIR}/python/etc/profile.d/conda.sh
    conda activate venv_sct
    python format_sct_analyze_lesion_table_max-per-slice.py -i /path/to/results -o all_subjects.xlsx
"""

import argparse
import re
from pathlib import Path
import pandas as pd


def get_parser() -> argparse.ArgumentParser:
    """Build and return the argument parser."""
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=
        "Format XLSX files produced by sct_analyze_lesion -perslice 1 for multiple subjects.\n"
        "For each subject, for the left (PAM50_12) and right (PAM50_13) spinal lemniscus separately:\n"
        "  1. Within each vertebral level, take the max across that level's slices.\n"
        "  2. Across vertebral levels, take the max of those per-level maxima.\n"
        "Left and right are handled independently, so their maxima may occur at different\n"
        "vertebral levels. All subjects are summarized in a single XLSX file (one row per subject).")
    ap.add_argument("-i", "--input-dir", type=Path, required=True,
                    help="Path to the directory containing per-subject XLSX files "
                         "named like 'sub-XXX_ses-YYY_..._label-lesion_analysis.xlsx'. "
                         "(output of `sct_analyze_lesion` run using sct_run_batch)")
    ap.add_argument("-sheet", choices=["lesion#1_distribution", "ROI_occupied_by_lesion"],
                    default="ROI_occupied_by_lesion",
                    help="Worksheet name. "
                         "lesion#1_distribution - the lesion is the reference (the percentage of the lesion that overlaps with the different regions). "
                         "ROI_occupied_by_lesion - the region is the reference (the percentage of the region affected by the lesion). "
                         "(default: ROI_occupied_by_lesion).")
    ap.add_argument("-o", "--out", type=Path, default=None,
                    help="Optional path to save the summary XLSX with all subjects. "
                         "If not provided, defaults to '<input-dir>/spinal_lemniscus_perslice_max_all_subjects.xlsx'.")
    ap.add_argument("-debug", "--debug", action="store_true",
                    help="Also report the slice (the 'row' index) from which each side's maximum is extracted. "
                         "Adds 'Left max slice' and 'Right max slice' columns to the output (each at its own "
                         "side's peak vertebral level, so the two may differ).")
    return ap


PAM50_MAP = {
    "PAM50_00": "WM left fasciculus gracilis",
    "PAM50_01": "WM right fasciculus gracilis",
    "PAM50_02": "WM left fasciculus cuneatus",
    "PAM50_03": "WM right fasciculus cuneatus",
    "PAM50_04": "Left lateral corticospinal tract",
    "PAM50_05": "Right lateral corticospinal tract",
    "PAM50_06": "WM left ventral spinocerebellar tract",
    "PAM50_07": "WM right ventral spinocerebellar tract",
    "PAM50_08": "WM left rubrospinal tract",
    "PAM50_09": "WM right rubrospinal tract",
    "PAM50_10": "Left lateral reticulospinal tract",
    "PAM50_11": "Right lateral reticulospinal tract",
    "PAM50_12": "Left spinal lemniscus",
    "PAM50_13": "Right spinal lemniscus",
    "PAM50_14": "WM left spino-olivary tract",
    "PAM50_15": "WM right spino-olivary tract",
    "PAM50_16": "Left ventrolateral reticulospinal tract",
    "PAM50_17": "Right ventrolateral reticulospinal tract",
    "PAM50_18": "WM left lateral vestibulospinal tract",
    "PAM50_19": "WM right lateral vestibulospinal tract",
    "PAM50_20": "Left ventral reticulospinal tract",
    "PAM50_21": "Right ventral reticulospinal tract",
    "PAM50_22": "WM left ventral corticospinal tract",
    "PAM50_23": "WM right ventral corticospinal tract",
    "PAM50_24": "WM left tectospinal tract",
    "PAM50_25": "WM right tectospinal tract",
    "PAM50_26": "Left medial reticulospinal tract",
    "PAM50_27": "Right medial reticulospinal tract",
    "PAM50_28": "WM left medial longitudinal fasciculus",
    "PAM50_29": "WM right medial longitudinal fasciculus",
    "PAM50_30": "GM left ventral horn",
    "PAM50_31": "GM right ventral horn",
    "PAM50_32": "GM left intermediate zone",
    "PAM50_33": "GM right intermediate zone",
    "PAM50_34": "GM left dorsal horn",
    "PAM50_35": "GM right dorsal horn",
    "white matter": "White matter",
    "gray matter": "Gray matter",
    "dorsal columns": "Dorsal columns",
    "lateral funiculi": "Lateral columns",
    "ventral funiculi": "Ventral columns",
}

# Left and right spinal lemniscus (spinothalamic + spinoreticular tracts)
SPINAL_LEMNISCUS = ["PAM50_12", "PAM50_13"]


def load_sheet_perslice(xlsx_path: Path, sheet: str) -> pd.DataFrame:
    """Load the Excel sheet for per-slice analysis and sanitize rows/columns.

    Args:
        xlsx_path: Path to the XLSX file.
        sheet: Sheet name to read, e.g., 'lesion#1_distribution'.

    Returns:
        DataFrame with per-slice data including 'row', 'vert_level', and tract columns.
    """
    df = pd.read_excel(xlsx_path, sheet_name=sheet, engine="openpyxl")
    df = df.copy()

    # Remove any summary rows if they exist - check for various possible summary row names
    summary_row_patterns = [
        "total % (all vert)",
        "total % (all slice)",
        "total %"
    ]

    for pattern in summary_row_patterns:
        df = df.loc[df["row"] != pattern]

    # Also filter out any rows where 'row' is not numeric (in case there are other text entries)
    df = df[pd.to_numeric(df["row"], errors='coerce').notna()]

    # Replace NaN with 0
    # Context: the last several columns (WM, GM, dorsal columns, etc) contain NaN, use 0 instead to be consistent with
    # the other columns
    df = df.fillna(0)

    # Ensure row is numeric
    df["row"] = df["row"].astype(int)

    return df


def _process_perslice_data(df: pd.DataFrame, columns_to_analyze: list) -> pd.DataFrame:
    """Process per-slice data to find maximum percentages within each vertebral level.

    Args:
        df: DataFrame with per-slice data
        columns_to_analyze: List of column names to analyze (tract/region columns)

    Returns:
        DataFrame with maximum percentages per vertebral level
    """
    # Group by vertebral level and compute maximum for each tract/region
    result_data = []

    # Get unique vertebral levels
    vertebral_levels = sorted(df['vert_level'].unique())

    for vert_level in vertebral_levels:
        # Get all slices for this vertebral level
        level_data = df[df['vert_level'] == vert_level]

        # Create result row for this vertebral level
        result_row = {'vert_level': vert_level}

        # For each tract column, find the maximum percentage across all slices
        for column in columns_to_analyze:
            if column in level_data.columns:
                max_percentage = level_data[column].max()
                result_row[column] = max_percentage
            else:
                result_row[column] = 0

        result_data.append(result_row)

    return pd.DataFrame(result_data)


def parse_subject_session(filename: str) -> tuple[str, str]:
    """Extract BIDS 'sub-XXX' and 'ses-YYY' entities from a filename.

    Args:
        filename: File name (or stem) to parse.

    Returns:
        Tuple of (subject, session); missing entities are returned as empty strings.
    """
    sub_match = re.search(r'(sub-[A-Za-z0-9]+)', filename)
    ses_match = re.search(r'(ses-[A-Za-z0-9]+)', filename)
    subject = sub_match.group(1) if sub_match else filename
    session = ses_match.group(1) if ses_match else ""
    return subject, session


def _side_max(processed_df: pd.DataFrame, filtered_df: pd.DataFrame, col: str) -> dict:
    """Find maximum across vertebral levels for one side (left or right).

    Step 1 (within-level max) is already applied in ``processed_df``; this takes the max of those
    per-level maxima (step 2), then finds the slice ('row') that produced it at that peak level.

    Args:
        processed_df: Per-level maxima (output of `_process_perslice_data`).
        filtered_df: The per-slice data (with 'row', 'vert_level' and the tract column).
        col: The tract column for this side (e.g., 'PAM50_12').

    Returns:
        Dict with 'value' (float, %), 'level' (int vertebral level) and 'slice' (int 'row'). 'level'
        and 'slice' are None when the value is 0 (no lesion in this side).
    """
    if col not in processed_df.columns:
        return {"value": 0.0, "level": None, "slice": None}

    # Max across vertebral levels of the per-level maxima
    idx_max = processed_df[col].idxmax()
    value = float(processed_df.loc[idx_max, col])
    if value <= 0:
        return {"value": 0.0, "level": None, "slice": None}

    peak_level = processed_df.loc[idx_max, "vert_level"]
    # Slice ('row') that produced this side's maximum at its peak level
    level_slices = filtered_df[filtered_df["vert_level"] == peak_level]
    slice_idx = int(level_slices.loc[level_slices[col].idxmax(), "row"])
    return {"value": value, "level": int(peak_level), "slice": slice_idx}


def compute_subject_max_spinal_lemniscus(xlsx_path: Path, sheet: str) -> dict | None:
    """Compute the maximum left and right spinal lemniscus percentages for one subject.

    Left (PAM50_12) and right (PAM50_13) are reduced independently: within each vertebral level take
    the max across slices (step 1), then take the max of those per-level maxima across levels (step 2).
    No averaging is performed, so the two sides may peak at different vertebral levels / slices.

    Args:
        xlsx_path: Path to the subject's XLSX file.
        sheet: Sheet name to read.

    Returns:
        Dict with 'left'/'right' (floats, %), 'left_level'/'right_level' (int) and
        'left_slice'/'right_slice' (int 'row'), or None if the required data is missing. Levels/slices
        are None for a side whose maximum is 0.
    """
    df = load_sheet_perslice(xlsx_path, sheet)

    if 'vert_level' not in df.columns:
        print(f"  Warning: 'vert_level' column not found in {xlsx_path.name}. Skipping.")
        return None

    present_tracts = [col for col in SPINAL_LEMNISCUS if col in df.columns]
    if not present_tracts:
        print(f"  Warning: spinal lemniscus columns {SPINAL_LEMNISCUS} not found in {xlsx_path.name}. Skipping.")
        return None

    # Keep only the identification columns plus the spinal lemniscus tracts
    columns_to_keep = ["row", "vert_level"] + present_tracts
    filtered_df = df[columns_to_keep].copy()

    # Step 1: maximum percentage per vertebral level (across slices) for each side
    processed_df = _process_perslice_data(filtered_df, present_tracts)
    left_col, right_col = SPINAL_LEMNISCUS
    if processed_df.empty:
        return {"left": 0.0, "right": 0.0, "left_level": None, "right_level": None,
                "left_slice": None, "right_slice": None}

    # Step 2: maximum across vertebral levels, independently for left/right sides
    left = _side_max(processed_df, filtered_df, left_col)
    right = _side_max(processed_df, filtered_df, right_col)

    return {"left": left["value"], "right": right["value"],
            "left_level": left["level"], "right_level": right["level"],
            "left_slice": left["slice"], "right_slice": right["slice"]}


def main() -> None:
    """Summarize the maximum left and right spinal lemniscus percentages across all subjects in a directory."""
    ap = get_parser()
    args = ap.parse_args()

    input_dir = args.input_dir
    if not input_dir.is_dir():
        print(f"Error: The input directory {input_dir} does not exist.")
        return

    # Collect per-subject XLSX files (skip temporary Excel lock files like '~$...')
    xlsx_files = sorted(
        f for f in input_dir.glob("*_label-lesion_analysis.xlsx")
        if not f.name.startswith("~$") and not f.name.startswith(".")
    )
    if not xlsx_files:
        print(f"Error: No '*_label-lesion_analysis.xlsx' files found in {input_dir}.")
        return

    print(f"Found {len(xlsx_files)} subject file(s) in {input_dir}")

    rows = []
    for xlsx_path in xlsx_files:
        subject, session = parse_subject_session(xlsx_path.name)
        print(f"Processing {subject} {session} ...")
        result = compute_subject_max_spinal_lemniscus(xlsx_path, args.sheet)
        if result is None:
            continue
        left_level = result["left_level"]
        right_level = result["right_level"]
        row = {
            "Subject": subject,
            "Session": session,
            "Left spinal lemniscus [%]": round(result["left"], 2),
            "Left level": f"C{left_level}" if left_level is not None else "",
        }
        if args.debug:
            row["Left max slice"] = result["left_slice"] if result["left_slice"] is not None else ""
        row["Right spinal lemniscus [%]"] = round(result["right"], 2)
        row["Right level"] = f"C{right_level}" if right_level is not None else ""
        if args.debug:
            row["Right max slice"] = result["right_slice"] if result["right_slice"] is not None else ""
        rows.append(row)

    if not rows:
        print("Error: No subjects could be processed.")
        return

    summary_df = pd.DataFrame(rows).sort_values(by="Subject").reset_index(drop=True)

    # Print the formatted table
    print("\nPer-slice analysis - Maximum spinal lemniscus percentage per subject:")
    print(summary_df.to_string(index=False))

    # Determine output path
    output_path = args.out
    if output_path is None:
        output_path = input_dir / "spinal_lemniscus_perslice_max_all_subjects.xlsx"
    if not str(output_path).endswith('.xlsx'):
        output_path = Path(str(output_path) + '.xlsx')

    summary_df.to_excel(output_path, index=False)
    print(f"\nResults saved to {output_path}")


if __name__ == "__main__":
    main()
