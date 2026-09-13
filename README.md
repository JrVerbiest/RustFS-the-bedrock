# RustFS — the bedrock

[![Olympus](https://img.shields.io/badge/project-Olympus-8A2BE2.svg)](https://jrverbiest.eu/projects/olympus/olympus.html)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![RustFS](https://img.shields.io/badge/RustFS-1.0.0--beta.12-orange.svg)](https://rustfs.com)
[![Docker Compose](https://img.shields.io/badge/orchestration-Docker%20Compose-2496ED.svg)](https://docs.docker.com/compose/)
[![uv](https://img.shields.io/badge/managed%20with-uv-de5fe9.svg)](https://docs.astral.sh/uv/)
[![Ruff](https://img.shields.io/badge/lint-ruff-red.svg)](https://docs.astral.sh/ruff/)

A local S3-compatible object store with least-privilege access built in: every
bucket is declared in one file, and every key that bucket needs is created,
scoped and then *tested* against what it must not be able to do.

Not tied to any particular data product or pipeline — declare the buckets you
want and it builds them.

> [!WARNING]
> **Not for production use.** This is for **local development and experimentation** only.
> store. It runs a single beta-version node with no replication, serves plain
> HTTP with no TLS, keeps every credential in a plaintext `.env` on one machine,
> and has no backup story. Treat anything in it as losable.

```bash
cp .env.example .env
make secrets      # invent strong credentials
make up           # start the store
make bootstrap    # create buckets, policies and keys
make test         # prove least privilege actually holds
```

## The Stack

| Layer | Component | Role |
| --- | --- | --- |
| Storage | [RustFS](https://rustfs.com) `1.0.0-beta.12` | S3-compatible object storage. |
| Administration | [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) `RELEASE.2025-08-13T08-35-41Z` | Creates the storage areas and the keys, and tests that the rules hold. Runs as a container. |
| Orchestration | Docker Compose | One long-running service, two one-shot jobs. |

Both images are pinned to an exact version, never `latest`, so a rebuild gives
back the store you already had rather than whatever was released this week.

## Requirements

| Tool | Why |
| --- | --- |
| [Docker Desktop](https://docs.docker.com/desktop/setup/install) | Everything runs in containers |
| [uv](https://docs.astral.sh/uv/) | Runs the one helper script, which invents the passwords |
| [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) — `brew install minio-mc` | Optional; only for driving the store by hand |

> [!NOTE]
> **Only tested on Apple Mac hardware running macOS.** The stack is pure Linux
> containers, so it should run anywhere Docker does, and CI exercises the
> identical images on Ubuntu — but a MacBook is the only platform this has
> actually been used on.

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
| Passwords live in one file, `.env` | Readable only by you, never committed — CI fails the build if it ever is |
| Bootstrapping only ever adds | Renaming or retiring a bucket leaves its old keys working. So every run ends with a **drift report** naming anything the store still has that is no longer declared. It tells you; it does not delete for you |

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

Declare your own buckets in `bootstrap/buckets.conf`; touch the `.example`
only to change the starting point everyone gets. CI fails the build if either
local file is ever committed.

## Commands

`make help` lists every target.

## License

MIT — see [LICENSE](LICENSE).
