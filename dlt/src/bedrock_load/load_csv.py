"""CSV files: one `<table>.csv` per table in the contract, audited and landed as they are.

Each run writes every table's file to `<job>/<table>/<load_id>.<file_id>.csv` in the bucket,
so every run adds a new copy.
"""

import csv
from pathlib import Path

from bedrock_load.audit import audit

SETTINGS = ("contract",)
"""What a `csv` job needs in `[<job>]` besides `folder`: the contract its files must pass."""


def check(settings: dict) -> dict:
    """Test the job's CSV files against its data contract, and return the contract.

    Parameters
    ----------
    settings : dict
        The job's settings from `.dlt/config.toml`.

    Returns
    -------
    dict
        The data contract the files passed.

    Raises
    ------
    SystemExit
        If no check ran, or any check did not pass.
    """
    return audit(settings["contract"], settings["folder"])


def files(pipeline, spec: dict, settings: dict, out: str) -> list[tuple[Path, str, list[str]]]:
    """Return the file of each table in the contract, for dlt to land.

    A CSV file in the folder that the contract does not describe is never returned, so it is
    never written.

    Parameters
    ----------
    pipeline : dlt.Pipeline
        The job's pipeline. Not needed: dlt lands the CSV files itself.
    spec : dict
        The data contract the files passed.
    settings : dict
        The job's settings from `.dlt/config.toml`.
    out : str
        Scratch folder for the run. Not needed.

    Returns
    -------
    list of (pathlib.Path, str, list of str)
        Each file, the table it is written to, and its columns.
    """
    paths = [Path(settings["folder"]) / f"{table['name']}.csv" for table in spec["schema"]]
    return [(path, path.stem, header(path)) for path in paths]


def header(path: Path) -> list[str]:
    """Return the column names on the first line of the CSV file at `path`."""
    with path.open(newline="", encoding="utf-8-sig") as f:
        return next(csv.reader(f), [])
