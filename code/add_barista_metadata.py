"""Populate BaRISTA atlas indices without altering source labels or coordinates."""

import argparse
import csv
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate without writing")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    metadata = json.loads((root / "electrodes.json").read_text())
    columns = ("barista_parcel_index", "barista_lobe_index")
    count = 0
    for path in sorted(root.glob("sub-*/ieeg/*_electrodes.tsv")):
        with path.open(newline="") as stream:
            reader = csv.DictReader(stream, delimiter="\t")
            fields = list(reader.fieldnames)
            rows = list(reader)
        for row in rows:
            for column in columns:
                spec = metadata[column]
                label = row[spec["SourceColumn"]].replace("-", "_").upper()
                index = spec["LabelToIndex"].get(label, 0)
                if not 0 <= index < spec["EmbeddingSize"]:
                    raise ValueError(f"Invalid index {index} for {column}")
                if args.check and row.get(column) != str(index):
                    raise ValueError(f"{path}: incorrect {column} for {row['name']}")
                row[column] = str(index)
            count += 1
        if not args.check:
            fields.extend(column for column in columns if column not in fields)
            with path.open("w", newline="") as stream:
                writer = csv.DictWriter(
                    stream, fields, delimiter="\t", lineterminator="\n"
                )
                writer.writeheader()
                writer.writerows(rows)
    print(f"{'Checked' if args.check else 'Updated'} {count} electrodes")


if __name__ == "__main__":
    main()
