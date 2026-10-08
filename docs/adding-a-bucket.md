# Adding a bucket

How to add a bucket to a running Bedrock store without touching the buckets it
already holds.

Adding a bucket only ever adds: the bootstrap creates what
`bootstrap/buckets.conf` declares and never deletes anything. The store keeps
running throughout — no restart is needed.

Run every command from the repository root.

## 1. Snapshot the existing buckets

Read-only. Records the size and version count of every bucket in the store, so
you can prove afterwards that nothing changed.

```bash
docker compose run --rm -T --entrypoint /bin/bash bootstrap -c '
mc alias set b "$RUSTFS_INTERNAL_ENDPOINT" "$RUSTFS_ROOT_USER" "$RUSTFS_ROOT_PASSWORD" >/dev/null
while read -r _ _ _ _ name; do mc du --versions "b/${name%/}"; done < <(mc ls b)' | tee /tmp/bedrock-before.txt
```

## 2. Declare the bucket

Append one line to `bootstrap/buckets.conf`, replacing `<bucket-name>` with the
name of the new bucket and `published` with its class:

```bash
echo '<bucket-name>    730   published' >> bootstrap/buckets.conf
tail -3 bootstrap/buckets.conf
```

The columns are: bucket name, days to keep superseded versions, class, and an
optional comma-separated list of extra consumers.

- Use `>>`, not `>`. A single `>` replaces the whole file.
- Names are lowercase letters, digits and hyphens, 3–63 characters, starting
  and ending with a letter or digit. An invalid name stops the bootstrap before
  it changes anything.
- Leave the existing lines alone. Removing one does not delete its bucket, but
  the bootstrap and the smoke test stop managing it, and the drift report flags
  it on every run.

| Class | Keys created | Use for |
| --- | --- | --- |
| `published` | publisher (put/get/list, no delete) and consumer (get/list) | data that is meant to be read |
| `restricted` | ingest (put/get/list, no delete) only — no reader key exists | raw or sensitive source data |

A data product typically gets a pair: a `-raw` bucket (`restricted`) and a
`-publish` bucket (`published`).

## 3. Generate its credentials

```bash
make secrets
```

Appends the variables the new bucket needs to `.env` and fills them. It never
overwrites a value that is already set: check that every existing credential is
listed under **kept (already set)**.

## 4. Create the bucket

```bash
make bootstrap
```

For the new bucket this creates it, turns on versioning, switches off anonymous
access, sets the lifecycle rule and creates its policies and keys. For existing
buckets it re-applies the same settings and deletes nothing. Re-applying does
close anonymous access and reset the lifecycle rule to the declared days, so
anything changed by hand on those two settings is put back.

The run ends with a **drift report**. Red `undeclared` lines name buckets,
policies or keys that exist in the store but not in `buckets.conf` — for
example, buckets whose lines were commented out. It is a report only. Do not
run the `mc rb --force` it suggests unless you mean to delete that bucket and
everything in it.

## 5. Verify the access rules

```bash
make test
```

For every declared bucket this writes `_smoke/probe.txt`, attempts the actions
each key must be refused, then removes only the `_smoke/` prefix with the root
credentials. Every line should read `PASS`.

## 6. Confirm the existing buckets are unchanged

```bash
docker compose run --rm -T --entrypoint /bin/bash bootstrap -c '
mc alias set b "$RUSTFS_INTERNAL_ENDPOINT" "$RUSTFS_ROOT_USER" "$RUSTFS_ROOT_PASSWORD" >/dev/null
while read -r _ _ _ _ name; do mc du --versions "b/${name%/}"; done < <(mc ls b)' | tee /tmp/bedrock-after.txt
diff /tmp/bedrock-before.txt /tmp/bedrock-after.txt
```

The only difference should be a `>` line for the new bucket. A line starting
with `<` means an existing bucket's size or version count changed — usually a
pipeline writing to it in the meantime. Find out which before going further.

## Handing out the keys

Variable names in `.env` are the bucket name upper-cased with `-` replaced by
`_`, followed by the role — `<bucket-name>` becomes `<BUCKET_NAME>`:

| Variable | Give to |
| --- | --- |
| `<BUCKET_NAME>_PUBLISHER_KEY` / `_SECRET` | the job that writes (published) |
| `<BUCKET_NAME>_CONSUMER_KEY` / `_SECRET` | readers (published) |
| `<BUCKET_NAME>_CONSUMER_<NAME>_KEY` / `_SECRET` | each extra consumer listed in the fourth column (published) |
| `<BUCKET_NAME>_INGEST_KEY` / `_SECRET` | the ingestion job (restricted) |

The endpoint to hand out is `RUSTFS_ENDPOINT_URL` in `.env`. The root
credentials are for the bootstrap only and are never handed out.

## What deletes data

| Command | Effect |
| --- | --- |
| `make destroy` | deletes the `bedrock-rustfs-data` volume (asks to confirm) |
| `docker compose down -v` / `--volumes` | deletes the `bedrock-rustfs-data` volume, without asking |
| `mc rb --force <alias>/<bucket>` | deletes the bucket and every object in it |

`make up`, `make down`, `make rebuild` and restarting Docker all keep the data
volume.
