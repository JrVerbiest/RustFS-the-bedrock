"""Run one load job: check a folder of files, then land them unchanged in a bucket.

A job is a group of sections in `.dlt/config.toml` and `.dlt/secrets.toml`, all named after
the job (see README.md). The job name is also the dlt pipeline name and the dataset: the
top-level folder the job writes to in the bucket. Its `format` picks the module that reads
and lands its files; everything else about a job is the same for every format.
"""

import argparse
import json
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import dlt

from bedrock_load import load_csv, load_sav

LOADERS = {"csv": load_csv, "sav": load_sav}
"""The module for each `format`. Each one has the same three members:

SETTINGS
    What a job of that format needs in `[<job>]` besides `folder`.
check(settings)
    Check the files before anything is written. Return the data contract they passed, or
    None for a format that is not tested against one.
files(pipeline, spec, settings, out)
    Return the files dlt lands, as `(path, table, columns)`.
"""


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


def run(job: str):
    """Run one job: check its files, then add them and their metadata to its bucket.

    Nothing is written unless the format's check passes. Bucket keys can put, get and list, but not
    delete. So every run appends under a new load id, and dlt is told not to clean anything
    up, in the bucket or on this machine.

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
        If the job's `format` is unknown, it is missing a setting, or its files fail the
        check or cannot be landed.
    """
    file_format = dlt.config.get(f"{job}.format") or "csv"
    loader = LOADERS.get(file_format)
    if loader is None:
        raise SystemExit(f'[{job}] `format` is one of {", ".join(LOADERS)}, not "{file_format}"')
    keys = ("folder", *loader.SETTINGS)
    settings = {key: dlt.config.get(f"{job}.{key}") for key in keys}
    missing = [f"`{key}`" for key, value in settings.items() if not value]
    if missing:
        raise SystemExit(f"[{job}] needs {', '.join(missing)} in .dlt/config.toml")

    with tempfile.TemporaryDirectory() as tmp:
        spec = loader.check(settings) or {}  # {}: no contract, so its id and version are null
        metadata = {
            "ingested_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "source_location": settings["folder"],
            "data_contract": spec.get("id"),
            "data_contract_version": spec.get("version"),
        }
        metadata_file = Path(tmp) / "_metadata.jsonl"
        metadata_file.write_text(json.dumps(metadata) + "\n")

        dlt.config["load.delete_completed_jobs"] = True  # keep no local copy of the data
        pipeline = dlt.pipeline(
            pipeline_name=job,
            dataset_name=job,
            destination=dlt.destinations.filesystem(max_state_files=0),  # never prune old state
        )
        resources = [land(*file) for file in loader.files(pipeline, spec, settings, tmp)]
        resources.append(land(metadata_file, "_metadata", list(metadata)))
        return pipeline.run(resources, write_disposition="append")  # never replace


def main() -> None:
    """Run the job named on the command line: `uv run load <job>`."""
    parser = argparse.ArgumentParser(prog="load", description="Run one load job.")
    parser.add_argument("job", help="name of the job's section in .dlt/config.toml")
    print(run(parser.parse_args().job))
