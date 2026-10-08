"""Run one ingestion job: audit a folder of CSV files, then land them unchanged in a bucket.

A job is a group of sections in `.dlt/config.toml` and `.dlt/secrets.toml`, all named after
the job (see README.md). The job name is also the dlt pipeline name and the dataset: the
top-level folder the job writes to in the bucket.
"""

import argparse
import csv
import json
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import dlt

from bedrock_ingest.audit import audit


def land(path: Path, table: str, columns: list[str]):
    """Return a dlt resource that writes the file at `path` to `table`, byte for byte.

    Parameters
    ----------
    path : pathlib.Path
        A `.csv` or `.jsonl` file.
    table : str
        The table, and so the folder in the bucket, the file is written to.
    columns : list of str
        The file's columns, recorded in dlt's schema.

    Returns
    -------
    dlt.extract.resource.DltResource
        One table, holding the file unchanged.
    """
    file_format = path.suffix.removeprefix(".")
    return dlt.resource(
        [dlt.mark.with_file_import(str(path), file_format)],
        name=table,
        file_format=file_format,
        columns={column: {"data_type": "text"} for column in columns},
    )


def header(path: Path) -> list[str]:
    """Return the column names on the first line of the CSV file at `path`."""
    with path.open(newline="", encoding="utf-8-sig") as f:
        return next(csv.reader(f), [])


def run(job: str):
    """Run one job: audit its CSV files, then add them and their metadata to its bucket.

    Only the files of the tables in the contract are written, and only if every check
    passes. Bucket keys can put, get and list, but not delete. So every run appends under a
    new load id, and dlt is told not to clean anything up, in the bucket or on this machine.

    Parameters
    ----------
    job : str
        Name of the job's section in `.dlt/config.toml`.

    Returns
    -------
    dlt.common.pipeline.LoadInfo
        What was loaded where: tables and files, never row values.

    Raises
    ------
    SystemExit
        If the job has no `folder` or `contract`, or the audit fails.
    """
    folder = dlt.config.get(f"{job}.folder")
    contract = dlt.config.get(f"{job}.contract")
    if not folder or not contract:
        raise SystemExit(f"[{job}] needs `folder` and `contract` in .dlt/config.toml")

    spec = audit(contract, folder)
    metadata = {
        "ingested_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "source_location": folder,
        "data_contract": spec.get("id"),
        "data_contract_version": spec.get("version"),
    }

    dlt.config["load.delete_completed_jobs"] = True  # keep no local copy of the data
    pipeline = dlt.pipeline(
        pipeline_name=job,
        dataset_name=job,
        destination=dlt.destinations.filesystem(max_state_files=0),  # never prune old state
    )
    with tempfile.TemporaryDirectory() as tmp:
        metadata_file = Path(tmp) / "_metadata.jsonl"
        metadata_file.write_text(json.dumps(metadata) + "\n")
        csv_files = [Path(folder) / f"{table['name']}.csv" for table in spec["schema"]]
        resources = [land(path, path.stem, header(path)) for path in csv_files]
        resources.append(land(metadata_file, "_metadata", list(metadata)))
        return pipeline.run(resources, write_disposition="append")  # never replace


def main() -> None:
    """Run the job named on the command line: `uv run ingest <job>`."""
    parser = argparse.ArgumentParser(prog="ingest", description="Run one ingestion job.")
    parser.add_argument("job", help="name of the job's section in .dlt/config.toml")
    print(run(parser.parse_args().job))
