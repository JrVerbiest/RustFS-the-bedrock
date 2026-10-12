# Loading data into the bedrock, with dlt

Puts files, CSV or SPSS `.sav`, into the bedrock's buckets using
[dlt](https://dlthub.com/docs/). A **job** is one folder of files into one
bucket, and it follows **Check, then Write**: nothing is written unless the
files pass their format's check. CSV files are audited against their data
contract; `.sav` files are not tested against a contract, only checked to be
SPSS files. Which folder goes into which bucket, in which format and under which
contract, is local configuration, gitignored like `../.env`, so nothing about a
deployment's data ends up in git.

```bash
cd dlt
uv sync
cp .dlt/config.toml.example .dlt/config.toml      # declare your jobs
cp .dlt/secrets.toml.example .dlt/secrets.toml    # one bucket key per job
uv run load <job>
```

Run it from `dlt/`. dlt reads its configuration from `.dlt/` in the current
directory.

## A job

Every section of a job is named after it. The job name is also the dlt pipeline
name, and the top-level folder the job writes to in the bucket. Use lowercase
letters, digits and underscores.

```toml
# .dlt/config.toml
[<job>]
format = "csv"        # or "sav"; "csv" when left out
folder = "<absolute path to the folder with the files>"
contract = "<absolute path to the data contract (ODCS YAML)>"    # csv only
# prefix = "<folder in the bucket>"                              # sav only

[<job>.destination.filesystem]
bucket_url = "s3://<bucket>"

[<job>.destination.filesystem.credentials]
endpoint_url = "<RUSTFS_ENDPOINT_URL from ../.env>"
region_name = "us-east-1"
```

```toml
# .dlt/secrets.toml
[<job>.destination.filesystem.credentials]
aws_access_key_id = "<the bucket's key from ../.env>"
aws_secret_access_key = "<the bucket's secret from ../.env>"
```

The bucket must exist first. Declare it in `../bootstrap/buckets.conf`, then run
`make secrets && make bootstrap` (see
[docs/adding-a-bucket.md](../docs/adding-a-bucket.md)). Give the job that
bucket's own key from `../.env`: `<BUCKET>_INGEST_KEY` / `_SECRET` for a
`restricted` bucket, `<BUCKET>_PUBLISHER_KEY` / `_SECRET` for a `published` one.
Never give it the root key.

## Formats

A job's `format` picks the module that checks, reads and lands its files.
Everything else (the metadata, the dlt load) is the same for every format.

| `format` | Module | `folder` holds | Checked by | Lands at | Also needs |
| --- | --- | --- | --- | --- | --- |
| `csv` | [`load_csv.py`](src/bedrock_load/load_csv.py) | one `<table>.csv` per table in the contract | the audit against the data contract | `<job>/<table>/<load_id>.<file_id>.csv`, a new copy every run | `contract` |
| `sav` | [`load_sav.py`](src/bedrock_load/load_sav.py) | any number of `.sav` files | **no data contract**: each file must start like an SPSS file | `<prefix>/<name>.sav`, under its own name, once | `prefix` |

### `sav`

For a consumer that reads the `.sav` files themselves, from a fixed place, under
their own names — such as a raw bucket's `prod/v1/2026/`.

- **No data contract.** A `sav` job is not tested against a data contract,
  and takes no `contract` setting. The only check is that every `.sav` file
  starts with the bytes of an SPSS file (`$FL2`, or `$FL3` when compressed), so
  a truncated download or a file saved under the wrong name stops the job
  before anything is written. Whatever reads the files is responsible for their
  contents; its `_metadata` records `data_contract` as `null`.
- **Write.** dlt loads tables, not files, so it cannot carry a `.sav` file
  itself. Each file is copied byte for byte, with the job's own destination
  client and key, to `<prefix>/<name>.sav`. A file the bucket already holds
  with the same content is left alone, so a re-run copies nothing. One it holds
  with *different* content stops the job before anything is copied: a consumer
  that loaded the old file would not notice the new one, so a changed delivery
  goes under a new prefix.
- **Record.** The dlt load writes `<job>/_files/`: one line per file, per run.

  ```json
  {"file": "wave_1.sav", "location": "s3://<bucket>/<prefix>/wave_1.sav", "md5": "6dc05bc7…", "status": "landed"}
  ```

  `status` is `landed` when this run copied it, `unchanged` when the bucket
  already held it.

### Adding a format

Add a module `load_<format>.py` with the same three members as the two above,
and register it in `LOADERS` in [`cli.py`](src/bedrock_load/cli.py):

| Member | What it is |
| --- | --- |
| `SETTINGS` | what a job of that format needs in `[<job>]` besides `folder` |
| `check(settings)` | checks the files before anything is written; returns the data contract they passed, or `None` when the format is not tested against one |
| `files(pipeline, spec, settings, out)` | the files dlt lands, as `(path, table, columns)` |

## Audit, then write (csv)

1. **Audit.** `<folder>/<table>.csv` is tested, for every table in the
   contract, with the [data contract CLI](https://cli.datacontract.com). The
   job prints the same results table as `datacontract test`, then its
   conclusion:

   ```text
   ╭────────┬──────────────────────────────────────────────┬───────┬─────────╮
   │ Result │ Check                                        │ Field │ Details │
   ├────────┼──────────────────────────────────────────────┼───────┼─────────┤
   │ passed │ Check that field 'id' is present             │ a.id  │         │
   │ passed │ Check that unique field id has no duplicate  │ a.id  │         │
   │        │ values                                       │       │         │
   ╰────────┴──────────────────────────────────────────────┴───────┴─────────╯
   🟢 Audit passed: 2 checks.
   ```

2. **Write.** Only if every check passed: the files, byte for byte, and one
   metadata file. Otherwise the job prints `🔴 Audit failed: nothing written.`
   and exits with status 1.

Only the tables in the contract are written. A CSV file in the folder that the
contract doesn't describe is never written.

## The metadata

Every load writes `_metadata/<load_id>.<file_id>.jsonl`: one JSON line, under
the same load id as the data.

```json
{"ingested_at": "2026-10-08T13:01:45+00:00", "source_location": "/data/csv", "data_contract": "<contract id>", "data_contract_version": "1.0.0"}
```

| Field | Meaning |
| --- | --- |
| `ingested_at` | when the job ran, in UTC |
| `source_location` | the job's `folder` |
| `data_contract`, `data_contract_version` | the `id` and `version` of the contract the data passed; `null` for a `sav` job, which is not tested against one |

## What lands where

```text
s3://<bucket>/<job>/
├── <table>/                          csv
│   ├── <load_id>.<file_id>.csv     ← run 1
│   └── <load_id>.<file_id>.csv     ← run 2
├── <table>/ …
├── _files/          sav: one file per load: which .sav files it landed
├── _metadata/       one file per load: when, from where, under which contract
├── _dlt_loads/      one entry per completed run: only trust files whose load id is here
├── _dlt_version/    the schema of each run: the columns of each table
├── _dlt_pipeline_state/
└── init

s3://<bucket>/<prefix>/               sav
├── <name>.sav
└── <name>.sav
```

File names under `<job>/` start with the run's load id. The newest complete
load is the highest load id in `_dlt_loads/`.

## It only adds

Bucket keys can put, get and list, but cannot delete (`../bootstrap/policies/`).
So a job never deletes or overwrites anything:

- Every run appends a new copy under a new load id. A past load stays as it
  was. Nothing is ever cleaned up automatically. Removing old loads is a
  deliberate operator action with the root key.
- A `sav` job lands each file once. It never writes over a file that is already
  there, even with the same name.
- Don't switch a job to dlt's `replace` write disposition or its `refresh`
  option. Both delete the previous files first, and the key will refuse.
- dlt normally prunes old `_dlt_pipeline_state` files after 100 runs. That is
  switched off for the same reason.

dlt normally also keeps a local copy of every loaded file in
`~/.dlt/pipelines/<job>/`. That is switched off too: once the data is in the
bucket, no copy stays behind on this machine.

## Lint

```bash
uv run ruff check . && uv run ruff format --check .
```

## TODO

- [ ] **Data contract check for `sav`.** A `sav` job is not yet tested against a
  data contract (see [`sav`](#sav)). What a prototype of it found:
  - Reading the files with [pyreadstat](https://github.com/Roche/pyreadstat),
    stacking them into the contract's one table and auditing that as one CSV
    file gives exactly the same result as auditing the source's own CSV export.
    DuckDB's `read_stat` extension is not published for the DuckDB version
    datacontract-cli installs, so pyreadstat is the reader to use.
  - The `syn_cnt_survey_data` contract does not pass the data contract CLI as
    it stands, on its CSV export either: templated column names such as
    `hh_member_age_{i}` are looked for literally, two `invalidValues` checks on
    one field (`country`) collide in datacontract-cli 1.2.4, and text columns
    holding `dd/MM/yyyy` with `logicalType: date` fail every row. Those need
    fixing in the contract before the check can be switched on.
