# Ingestion into the bedrock, with dlt

Puts CSV files into the bedrock's buckets using [dlt](https://dlthub.com/docs/).
A **job** is one folder of CSV files into one bucket, and it follows **Audit,
then Write**: the files are tested against their data contract first, and
nothing is written unless every test passes. Which folder goes into which bucket,
and under which contract, is local configuration, gitignored like `../.env`, so
nothing about a deployment's data ends up in git.

```bash
cd dlt
uv sync
cp .dlt/config.toml.example .dlt/config.toml      # declare your jobs
cp .dlt/secrets.toml.example .dlt/secrets.toml    # one bucket key per job
uv run ingest <job>
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
folder = "<absolute path to the folder with one <table>.csv per table>"
contract = "<absolute path to the data contract (ODCS YAML)>"

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

## Audit, then write

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

2. **Write.** Only if every check passed: each table's CSV file, byte for byte,
   and one metadata file. Otherwise the job prints
   `🔴 Audit failed: nothing written.` and exits with status 1.

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
| `data_contract`, `data_contract_version` | the `id` and `version` of the contract the data passed |

## What lands where

```text
s3://<bucket>/<job>/
├── <table>/
│   ├── <load_id>.<file_id>.csv     ← run 1
│   └── <load_id>.<file_id>.csv     ← run 2
├── <table>/ …
├── _metadata/       one file per load: when, from where, under which contract
├── _dlt_loads/      one entry per completed run: only trust files whose load id is here
├── _dlt_version/    the schema of each run: the columns from each CSV header
├── _dlt_pipeline_state/
└── init
```

File names start with the run's load id. The newest complete load is the
highest load id in `_dlt_loads/`.

## It only adds

Bucket keys can put, get and list, but cannot delete (`../bootstrap/policies/`).
So a job never deletes or overwrites anything:

- Every run appends a new copy under a new load id. A past load stays as it
  was. Nothing is ever cleaned up automatically. Removing old loads is a
  deliberate operator action with the root key.
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
