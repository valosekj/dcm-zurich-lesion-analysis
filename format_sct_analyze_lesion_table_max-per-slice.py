"""
Script to format XLSX table produced by `sct_analyze_lesion -perslice 1` (i.e., one row per slice).
This script processes per-slice data from the "ROI_occupied_by_lesion" Excel sheet where each row represents a slice,
groups them by vertebral level, and gets the maximum percentage across slices within each vertebral level.
The results are saved in two formats:
    1. Left and right tracts combined (e.g., "Lateral corticospinal tracts").
    2. Left and right tracts kept separate.

Sample output table:
        Vertebral level     Spinal lemniscus (Spinothalamic + Spinoreticular tracts) [%]
                     C3     95
                     C4     50
  Maximum across levels     95

Usage:
    source ${SCT_DIR}/python/etc/profile.d/conda.sh
    conda activate venv_sct
    python format_sct_analyze_lesion_table_max-per-slice.py --xlsx input.xlsx
"""

#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path
import pandas as pd


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
    df = df.fillna(0)

    # Ensure row is numeric
    df["row"] = df["row"].astype(int)

    return df


def process_perslice_data(df: pd.DataFrame, columns_to_analyze: list) -> pd.DataFrame:
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

        # For each tract/region column, find the maximum percentage across all slices
        for column in columns_to_analyze:
            if column in level_data.columns:
                max_percentage = level_data[column].max()
                result_row[column] = max_percentage
            else:
                result_row[column] = 0

        result_data.append(result_row)

    return pd.DataFrame(result_data)


def save_table_combined_tracts_perslice(args, processed_df, spinal_lemniscus):
    """Save table with left and right tracts combined for per-slice analysis."""
    # Make a copy to avoid modifying the original
    filtered_df = processed_df.copy()

    # Combine the left and right spinal lemniscus tracts
    if all(tract in filtered_df.columns for tract in spinal_lemniscus):
        filtered_df["Spinal lemniscus"] = filtered_df[spinal_lemniscus].mean(axis=1)
        # Drop the individual columns
        filtered_df = filtered_df.drop(columns=spinal_lemniscus)

    # Rename columns based on PAM50_MAP
    column_rename_map = {"vert_level": "Vertebral level"}
    for col in filtered_df.columns:
        if col in PAM50_MAP:
            column_rename_map[col] = PAM50_MAP[col]
    filtered_df = filtered_df.rename(columns=column_rename_map)

    # Define the desired column order (after renaming)
    desired_order = ["Vertebral level",
                     "Spinal lemniscus"]

    # Ensure the columns exist in the dataframe
    final_order = ["Vertebral level"] + [col for col in desired_order[1:] if col in filtered_df.columns]

    # Reorder the columns
    filtered_df = filtered_df[final_order]

    # Add '[%]' suffix to column names except 'Vertebral level'
    filtered_df.columns = [
        col if col == "Vertebral level" else f"{col} [%]"
        for col in filtered_df.columns
    ]

    # Round numbers to two decimals
    for col in filtered_df.columns:
        if col != "Vertebral level":
            filtered_df[col] = filtered_df[col].round(2)

    # Format 'Vertebral level' as 'C1', 'C2', ...
    filtered_df["Vertebral level"] = filtered_df["Vertebral level"].apply(lambda x: f"C{int(x)}")

    # Drop rows where all percentage columns are zero
    percentage_columns = [col for col in filtered_df.columns if col != "Vertebral level"]
    filtered_df = filtered_df[(filtered_df[percentage_columns] != 0).any(axis=1)]
    filtered_df = filtered_df.reset_index(drop=True)

    # Add a new row 'Maximum across vertebral levels'
    max_row = {"Vertebral level": "Maximum across levels"}
    for col in percentage_columns:
        max_row[col] = filtered_df[col].max()
    filtered_df = pd.concat([filtered_df, pd.DataFrame([max_row])], ignore_index=True)

    # Print the formatted table
    print("Per-slice analysis - Maximum percentages per vertebral level:")
    print(filtered_df.to_string(index=False))

    # Save to Excel if output path is provided
    if args.out is not None:
        output_path = args.out
        if not str(output_path).endswith('.xlsx'):
            output_path = str(output_path) + '.xlsx'
        output_path = str(output_path).replace('.xlsx', '_perslice_combined.xlsx')
        filtered_df.to_excel(output_path, index=False)
        print(f"Results saved to {output_path}")


def save_table_left_and_right_tracts_perslice(args, processed_df):
    """Save table with left and right tracts separately for per-slice analysis."""
    # Make a copy to avoid modifying the original
    filtered_df = processed_df.copy()

    # Rename columns based on PAM50_MAP
    column_rename_map = {"vert_level": "Vertebral level"}
    for col in filtered_df.columns:
        if col in PAM50_MAP:
            column_rename_map[col] = PAM50_MAP[col]
    filtered_df = filtered_df.rename(columns=column_rename_map)

    # Define the desired column order (after renaming)
    desired_order = ["Vertebral level",
                     "Left spinal lemniscus",
                     "Right spinal lemniscus"]

    # Ensure the columns exist in the dataframe
    final_order = ["Vertebral level"] + [col for col in desired_order[1:] if col in filtered_df.columns]

    # Reorder the columns
    filtered_df = filtered_df[final_order]

    # Add '[%]' suffix to column names except 'Vertebral level'
    filtered_df.columns = [
        col if col == "Vertebral level" else f"{col} [%]"
        for col in filtered_df.columns
    ]

    # Round numbers to integers
    for col in filtered_df.columns:
        if col != "Vertebral level":
            filtered_df[col] = filtered_df[col].round().astype(int)

    # Format 'Vertebral level' as 'C1', 'C2', ...
    filtered_df["Vertebral level"] = filtered_df["Vertebral level"].apply(lambda x: f"C{int(x)}")

    # Drop rows where all percentage columns are zero
    percentage_columns = [col for col in filtered_df.columns if col != "Vertebral level"]
    filtered_df = filtered_df[(filtered_df[percentage_columns] != 0).any(axis=1)]
    filtered_df = filtered_df.reset_index(drop=True)

    # Add a new row 'Maximum across vertebral levels'
    max_row = {"Vertebral level": "Maximum across levels"}
    for col in percentage_columns:
        max_row[col] = filtered_df[col].max()
    filtered_df = pd.concat([filtered_df, pd.DataFrame([max_row])], ignore_index=True)

    # Print the formatted table
    print("\nPer-slice analysis - Maximum percentages per vertebral level (separate left/right tracts):")
    print(filtered_df)

    # Save to Excel if output path is provided
    if args.out is not None:
        output_path = args.out
        if not str(output_path).endswith('.xlsx'):
            output_path = str(output_path) + '.xlsx'
        output_path = str(output_path).replace('.xlsx', '_perslice_left_and_right_tracts_RST.xlsx')
        filtered_df.to_excel(output_path, index=False)
        print(f"Results saved to {output_path}")


def main() -> None:
    """Read per-slice XLSX table, compute maximum percentages per vertebral level, print and optionally save."""
    ap = argparse.ArgumentParser(description=
                                 "Format XLSX table produced by sct_analyze_lesion -perslice 1. "
                                 "Processes per-slice data to find maximum percentages within each vertebral level.")
    ap.add_argument("-xlsx", type=Path, help="Path to XLSX file.")
    ap.add_argument("-sheet", choices=["lesion#1_distribution", "ROI_occupied_by_lesion"],
                    default="ROI_occupied_by_lesion",
                    help="Worksheet name. "
                         "lesion#1_distribution - the lesion is the reference (the percentage of the lesion that overlaps with the different regions). "
                         "ROI_occupied_by_lesion - the region is the reference (the percentage of the region affected by the lesion). "
                         "(default: ROI_occupied_by_lesion).")
    ap.add_argument("-out", type=Path, default=None,
                    help="Optional path to save XLSX with the results. "
                         "If not provided, results will only be printed to the console.")
    args = ap.parse_args()

    # Check if args.xlsx is provided and if the path exists
    if args.xlsx is None:
        print("Error: --xlsx argument is required.")
        return
    if not args.xlsx.exists():
        print(f"Error: The file {args.xlsx} does not exist.")
        return

    # Load the per-slice data
    df = load_sheet_perslice(args.xlsx, args.sheet)

    # Check if required columns exist
    if 'vert_level' not in df.columns:
        print("Error: 'vert_level' column not found in the data. This script requires per-slice data with vertebral level information.")
        return

    # Add spinal lemniscus columns (spinothalamic+spinoreticular)
    spinal_lemniscus = ["PAM50_12", "PAM50_13"]  # left and right spinal lemniscus

    # Filter dataframe to keep only the selected columns plus required identification columns
    columns_to_keep = ["row", "vert_level"] + [col for col in spinal_lemniscus if col in df.columns]
    filtered_df = df[columns_to_keep].copy()

    # print(f"Processing per-slice data with {len(filtered_df)} slices across {len(filtered_df['vert_level'].unique())} vertebral levels...")

    # Process the per-slice data to get maximum percentages per vertebral level
    processed_df = process_perslice_data(filtered_df, spinal_lemniscus)

    # Generate both types of output tables
    save_table_combined_tracts_perslice(args, processed_df, spinal_lemniscus)
    # save_table_left_and_right_tracts_perslice(args, processed_df)


if __name__ == "__main__":
    main()
