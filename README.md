# RustFS — the bedrock

[![Status: work in progress](https://img.shields.io/badge/status-work%20in%20progress-yellow.svg)](#why-the-bedrock)
[![Last update](https://img.shields.io/github/last-commit/JrVerbiest/RustFS-the-bedrock.svg)](https://github.com/JrVerbiest/RustFS-the-bedrock/commits/main)

[![RustFS](https://img.shields.io/badge/RustFS-1.0.0--beta.12-orange.svg)](https://rustfs.com)
[![Docker Compose](https://img.shields.io/badge/orchestration-Docker%20Compose-2496ED.svg)](https://docs.docker.com/compose/)
[![uv](https://img.shields.io/badge/managed%20with-uv-de5fe9.svg)](https://docs.astral.sh/uv/)
[![Ruff](https://img.shields.io/badge/lint-ruff-red.svg)](https://docs.astral.sh/ruff/)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A local S3-compatible object store with least-privilege access built in: every
bucket is declared in one file, and every key that bucket needs is created,
scoped and then *tested* against what it must not be able to do.

## Why the bedrock

RustFS is the bedrock of our data platform — a shared storage foundation. Built in Rust
with S3-compatible access.

> [!WARNING]
> **Not for production use.** This is for **local development and
> experimentation** only. It runs a single beta-version node with no
> replication, serves plain HTTP with no TLS, keeps every credential in a
> plaintext `.env` on one machine, and has no backup story. Treat anything in
> it as losable.

## Requirements

| Tool | Why |
| --- | --- |
| [Docker Desktop](https://docs.docker.com/desktop/setup/install) | Everything runs in containers |
| [uv](https://docs.astral.sh/uv/) | Runs the one helper script, which invents the passwords |
| `make` | The entry point for every command below; preinstalled on macOS |
| [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) — `brew install minio-mc` | Optional; only for driving the store by hand |

> [!NOTE]
> **Only tested on Apple Mac hardware running macOS.** The stack is pure Linux containers, so it should run anywhere Docker does, but a MacBook is the only
> platform this has actually been used on.

## Quick start

```bash
cp .env.example .env
make secrets      # invent strong credentials
make up           # start the store
make bootstrap    # create buckets, policies and keys
make test         # prove least privilege actually holds
```

Every line of `make test` should read `PASS`. The store is then serving on
`http://127.0.0.1:9000` (S3 API) and `http://127.0.0.1:9001` (console). If you
changed the ports in `.env`, `make console` prints the console URL.

## The stack

| Layer | Component | Role |
| --- | --- | --- |
| Storage | [RustFS](https://rustfs.com) `1.0.0-beta.12` | S3-compatible object storage. |
| Administration | [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) `RELEASE.2025-08-13T08-35-41Z` | Creates the storage areas and the keys, and tests that the rules hold. Runs as a container. |
| Orchestration | Docker Compose | One long-running service, two one-shot jobs. |
| Loading | [dlt](https://dlthub.com/docs/) package in [`dlt/`](dlt/) | Puts files from a local drive into the buckets. |

Both images are pinned to an exact version, never `latest`, so a rebuild gives
back the store you already had rather than whatever was released this week.

## How it works

A **bucket** is a named storage area. Each is declared in
`bootstrap/buckets.conf` with a **class**, and the class alone decides which
keys get created for it.

| Class | Keys created | What goes in it |
| --- | --- | --- |
| `published` | A **publisher** key (write + read, no delete) and a **consumer** key (read only) | Finished data that is meant to be read |
| `restricted` | An **ingest** key only (write + read, no delete) | Raw or sensitive source data |

A `restricted` bucket gets **no reader key at all**, so there is no credential
anywhere that a reader could be handed.

Declared out of the box by
[`bootstrap/buckets.conf.example`](bootstrap/buckets.conf.example), as a
working example:

| Bucket | Class | Contents |
| --- | --- | --- |
| `example-publish` | `published` | Checked output, safe to hand a consumer key out |
| `example-raw` | `restricted` | Raw source data, readable only by the ingestion job |

A published bucket can also name **extra consumers** in an optional fourth
column. Each gets its own key on the same read-only policy, so one reader can
be revoked without rotating the key every other reader shares.

### The rules it enforces

| Rule | Why it matters |
| --- | --- |
| Only the root key can delete | A broken job cannot destroy the archive |
| Every bucket keeps old versions | Overwriting a file leaves the previous one recoverable. Superseded versions are cleaned up after the configured number of days; current files are never removed automatically |
| Nothing is readable without a key | Anonymous access is switched off on every run, so a bucket someone once opened up gets closed again |
| Both network ports are bound to loopback | `127.0.0.1` only. Nothing else on the network can reach the store, by accident or otherwise |
| Passwords live in one file, `.env` | Readable only by you (`0600`) and gitignored, so it is never committed |
| Bootstrapping only ever adds | Renaming or retiring a bucket leaves its old keys working. So every run ends with a **drift report** naming anything the store still has that is no longer declared. It tells you; it does not delete for you |

`make test` is what makes these more than a policy file: it tries each
forbidden action with each key and fails unless the store refuses it.

### Where things live

One file is the source of truth — `bootstrap/buckets.conf`. The builder
creates from it, the credential helper generates from it, and the smoke test
checks against it. Change that one file, re-run, and the other three follow.
Nothing else needs editing to add, resize or retire a bucket.

That file is **yours and gitignored**, exactly like `.env`: which buckets a
deployment carries is that deployment's business, not something to publish.
What the repository carries is an example of each:

| Committed | Local, gitignored | Created by |
| --- | --- | --- |
| [`.env.example`](.env.example) | `.env` | `make secrets` — then filled with random credentials |
| [`bootstrap/buckets.conf.example`](bootstrap/buckets.conf.example) | `bootstrap/buckets.conf` | any `make` target that needs it — a straight copy, ready to use |
| [`dlt/.dlt/config.toml.example`](dlt/.dlt/config.toml.example) | `dlt/.dlt/config.toml` | you — which folder of files goes into which bucket, in which format |
| [`dlt/.dlt/secrets.toml.example`](dlt/.dlt/secrets.toml.example) | `dlt/.dlt/secrets.toml` | you — each job's bucket key, copied from `.env` |

Declare your own buckets in `bootstrap/buckets.conf`; touch the `.example`
only to change the starting point everyone gets.

## Using the store

The credentials for each bucket are in `.env`, named after the bucket and the role: `EXAMPLE_PUBLISH_CONSUMER_KEY` / `_SECRET`, `EXAMPLE_RAW_INGEST_KEY` / `_SECRET`, and so on. Hand a job the key for its own bucket and role, never the root credentials, which exist for the bootstrap alone.

To read a published bucket by hand with `mc`:

```bash
set -a; . ./.env; set +a
mc alias set bedrock "$RUSTFS_ENDPOINT_URL" "$EXAMPLE_PUBLISH_CONSUMER_KEY" "$EXAMPLE_PUBLISH_CONSUMER_SECRET"
mc ls bedrock/example-publish
```

### Adding a bucket

1. Append a line to `bootstrap/buckets.conf` (not to the `.example`).
2. `make secrets` — appends and fills the credentials it needs.
3. `make bootstrap` — creates the bucket. The store keeps running.
4. `make test` — verifies the access rules.

The full walkthrough, including how to prove the existing buckets were left
untouched, is in [docs/adding-a-bucket.md](docs/adding-a-bucket.md).

## Getting data in

[`dlt/`](dlt/) is a small [dlt](https://dlthub.com/docs/) package that puts
files on a local drive, CSV or SPSS `.sav`, into the buckets. See
[dlt/README.md](dlt/README.md).

This package will be extended in future to load data from other sources.

## Commands

`make help` lists every target with a one-line description.

| Target | What it does |
| --- | --- |
| `make secrets` | Fill `.env` with strong random credentials; never overwrites real ones |
| `make up` | Start the store and wait until it reports healthy |
| `make bootstrap` | Create buckets, policies and keys; safe to re-run |
| `make test` | Assert the access policies deny what they must |
| `make status` | Show what is running |
| `make logs` | Follow the store's logs |
| `make console` | Print the console URL |
| `make down` | Stop the store; the data is kept |
| `make rebuild` | Pull the pinned images, recreate the containers, bootstrap and verify; the data is kept |
| `make destroy` | Stop the store **and delete all data**; asks you to type `DESTROY` first |
| `make lint` | Lint the credential helper, the dlt package and the shell scripts |

## License

MIT — see [LICENSE](LICENSE).
