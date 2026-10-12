"""SPSS `.sav` files: landed as they are, under their own names. No data contract is tested.

dlt loads tables, not files, so it cannot carry a `.sav` file itself. The files are copied
byte for byte with the job's own destination client, to `<prefix>/<name>` in the bucket, and
the dlt load records which files each run landed in `<job>/_files/`.
"""

import hashlib
import json
from pathlib import Path

SETTINGS = ("prefix",)
"""What a `sav` job needs in `[<job>]` besides `folder`: where its files land."""

SAV_MAGIC = (b"$FL2", b"$FL3")
"""The first bytes of an SPSS file: `$FL2` for `.sav`, `$FL3` for compressed `.zsav`."""

FILE_COLUMNS = ["file", "location", "md5", "status"]
"""The columns of the `_files` table: one row per `.sav` file, per run."""


def check(settings: dict) -> None:
    """Check that every `.sav` file in the job's folder is an SPSS file.

    There is no data contract to test them against, so this is the only check. It stops a
    truncated download or a file saved under the wrong name before anything is written.

    Parameters
    ----------
    settings : dict
        The job's settings from `.dlt/config.toml`.

    Returns
    -------
    None
        No data contract was tested.

    Raises
    ------
    SystemExit
        If a file is not an SPSS file.
    """
    for path in sav_files(settings["folder"]):
        with path.open("rb") as f:
            if f.read(4) not in SAV_MAGIC:
                raise SystemExit(f"🔴 {path.name} is not an SPSS file: nothing written.")


def files(pipeline, spec: dict, settings: dict, out: str) -> list[tuple[Path, str, list[str]]]:
    """Copy the job's `.sav` files into the bucket, and return the record of them for dlt.

    Parameters
    ----------
    pipeline : dlt.Pipeline
        The job's pipeline, whose destination client does the copying.
    spec : dict
        Empty: no data contract is tested.
    settings : dict
        The job's settings from `.dlt/config.toml`.
    out : str
        Scratch folder for the run; the record is written here.

    Returns
    -------
    list of (pathlib.Path, str, list of str)
        One file for the `_files` table, and its columns.
    """
    with pipeline.destination_client() as client:
        record = copy(client, settings["prefix"], settings["folder"], out)
    return [(record, "_files", FILE_COLUMNS)]


def copy(client, prefix: str, folder: str, out: str) -> Path:
    """Copy the `.sav` files in `folder` to `<prefix>/<name>` in the bucket, byte for byte.

    A file the bucket already holds with the same content is left alone, so a re-run copies
    nothing. One it holds with *different* content stops the job before anything is copied:
    a consumer that loaded the old file would not notice the new one, and a changed delivery
    belongs under a new prefix, not over the old one.

    Parameters
    ----------
    client : dlt.destinations.impl.filesystem.filesystem.FilesystemClient
        The job's destination client: its bucket, credentials and filesystem.
    prefix : str
        Folder in the bucket the files land in, such as `prod/v1/2026`.
    folder : str
        Folder holding the `.sav` files.
    out : str
        Folder the record of the files is written to.

    Returns
    -------
    pathlib.Path
        `<out>/_files.jsonl`: one line per file, with where it is, its md5, and whether this
        run `landed` it or found it `unchanged`.

    Raises
    ------
    SystemExit
        If the bucket holds a file of the same name with different content.
    """
    fs = client.fs_client
    root = f"{client.bucket_path}/{prefix.strip('/')}"
    plan = []
    for path in sav_files(folder):
        key = f"{root}/{path.name}"
        with path.open("rb") as f:
            digest = md5(f)
        status = "landed"
        if fs.exists(key):
            with fs.open(key, "rb") as f:
                if md5(f) != digest:
                    raise SystemExit(
                        f"🔴 {client.make_remote_url(key)} already holds a different "
                        f"{path.name}: nothing written. A changed file goes under a new prefix."
                    )
            status = "unchanged"
        plan.append((path, key, digest, status))

    fs.makedirs(root, exist_ok=True)  # a local bucket needs the folder; S3 has none to make
    for path, key, _, status in plan:
        if status == "landed":
            fs.put_file(str(path), key)

    record = Path(out) / "_files.jsonl"
    with record.open("w") as f:
        for path, key, digest, status in plan:
            row = [path.name, client.make_remote_url(key), digest, status]
            f.write(json.dumps(dict(zip(FILE_COLUMNS, row, strict=True))) + "\n")
    return record


def sav_files(folder: str) -> list[Path]:
    """Return the `.sav` files in `folder`, by name.

    Raises
    ------
    SystemExit
        If there are none.
    """
    paths = sorted(Path(folder).glob("*.sav"))
    if not paths:
        raise SystemExit(f"No .sav files in {folder}")
    return paths


def md5(f) -> str:
    """Return the md5 hex digest of the binary file object `f`."""
    return hashlib.file_digest(f, "md5").hexdigest()
