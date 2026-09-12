#!/usr/bin/env python3
"""Fill the CHANGE_ME placeholders in ``.env`` with strong random credentials.

Why a script and not ``openssl rand`` in the README: credentials a human types
are credentials a human reuses. This module generates one distinct value per
placeholder and refuses to touch a line that already holds a real value, so it
is safe to re-run.

It also reads ``bootstrap/buckets.conf`` and appends any credential the declared
buckets need but ``.env`` does not yet have, so adding a bucket is two steps --
a line in ``buckets.conf``, then ``make secrets``.

Notes
-----
The file is rewritten in place with ``0600`` permissions. Nothing generated is
printed: a secret echoed into a scrollback buffer or a CI log is a leaked
secret.

Key rotation is a consequence of the "never overwrite a real value" rule rather
than a separate feature:

* Blank a ``*_SECRET`` and re-run -- the access key id is unchanged, so the
  bootstrap updates that user's secret in place.
* Blank both the ``*_KEY`` and the ``*_SECRET`` -- a new key id is generated,
  the bootstrap creates a *new* user, and the old one survives until it is
  removed by hand. The bootstrap's drift report names it on every run until
  then.

Examples
--------
Run through the Makefile, which is the supported entry point::

    make secrets

Or directly, against an explicit file::

    uv run python scripts/generate_secrets.py .env

See Also
--------
bootstrap/bootstrap.sh : Consumes these credentials, and is the authority on
    which roles each bucket class requires.
bootstrap/buckets.conf : Declares the buckets whose credentials are generated.
"""

import os
import secrets
import stat
import sys
from pathlib import Path

PLACEHOLDER = "CHANGE_ME"

# Access key IDs end up in logs, policy names and error messages, so they are
# readable; secrets are not.
KEY_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"

# Which roles each bucket class needs credentials for. Must match
# roles_for_class() in bootstrap/bootstrap.sh -- the bootstrap is the authority,
# this only decides what to pre-generate.
ROLES_BY_CLASS = {
    "published": ("PUBLISHER", "CONSUMER"),
    "restricted": ("INGEST",),
}


def new_key(var_name: str) -> str:
    """Build a readable but unguessable access key id from a variable name.

    The key id is an identifier, not a secret: it appears in bucket policies, in
    ``mc admin user list`` and in error messages, so it is derived from the
    variable name to stay greppable. The random suffix is what stops it being
    predictable from ``buckets.conf`` alone.

    Parameters
    ----------
    var_name : str
        The environment variable name the key is for, e.g.
        ``"EXAMPLE_PUBLISH_PUBLISHER_KEY"``. A trailing ``"_KEY"`` is stripped;
        anything else is used as-is.

    Returns
    -------
    str
        The lower-cased stem followed by eight random characters from
        :data:`KEY_CHARS`, e.g. ``"example_publish_publisher_k3f9x2qa"``.

    See Also
    --------
    new_secret : Generates the matching secret access key.

    Examples
    --------
    >>> new_key("EXAMPLE_PUBLISH_PUBLISHER_KEY")  # doctest: +SKIP
    'example_publish_publisher_k3f9x2qa'
    """
    stem = var_name.removesuffix("_KEY").lower()
    suffix = "".join(secrets.choice(KEY_CHARS) for _ in range(8))
    return f"{stem}_{suffix}"


def new_secret() -> str:
    """Generate one secret access key.

    Returns
    -------
    str
        A URL-safe base64 string carrying 32 bytes of entropy (43 characters).

    Notes
    -----
    URL-safe so it survives ``.env`` parsing, shell quoting and S3 request
    signing without escaping, and comfortably over the 16-character minimum the
    bootstrap enforces.

    See Also
    --------
    new_key : Generates the matching access key id.
    """
    return secrets.token_urlsafe(32)


def required_variables(buckets_conf: Path) -> list[str]:
    """List the credential variables the declared buckets imply.

    Reads ``buckets.conf`` and expands each bucket into the variables its class
    requires, so a bucket declared there cannot be forgotten in ``.env``.

    Parameters
    ----------
    buckets_conf : Path
        Path to ``bootstrap/buckets.conf``. A missing file yields an empty list
        rather than an error, so the script still works on a checkout where only
        ``.env`` matters.

    Returns
    -------
    list of str
        Variable names in declaration order, ``_KEY`` before ``_SECRET`` for
        each role, e.g. ``["EXAMPLE_PUBLISH_PUBLISHER_KEY",
        "EXAMPLE_PUBLISH_PUBLISHER_SECRET", ...]``. Names are not de-duplicated;
        the caller filters against what ``.env`` already has.

    Notes
    -----
    Malformed lines are skipped rather than raising: the bootstrap validates
    ``buckets.conf`` properly and reports the error, and this helper should not
    be the thing that fails first with a worse message.

    The optional fourth column of ``buckets.conf`` names extra readers of a
    published bucket. Each becomes a ``CONSUMER_<NAME>`` role with a key of its
    own on the shared read-only policy, so one reader can be revoked without
    rotating the key every other reader shares.
    """
    if not buckets_conf.exists():
        return []
    wanted: list[str] = []
    for raw in buckets_conf.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 3:
            continue
        bucket, _days, klass = fields[0], fields[1], fields[2]
        prefix = bucket.replace("-", "_").upper()
        roles = list(ROLES_BY_CLASS.get(klass, ()))
        # The optional fourth column names extra readers of a published bucket,
        # each of which gets its own key on the shared read-only policy.
        if klass == "published" and len(fields) >= 4:
            roles += [f"CONSUMER_{name.upper()}" for name in fields[3].split(",") if name]
        for role in roles:
            wanted += [f"{prefix}_{role}_KEY", f"{prefix}_{role}_SECRET"]
    return wanted


def main() -> int:
    """Fill an ``.env`` file with the credentials ``buckets.conf`` implies.

    Appends any missing variable, generates a value for every credential that is
    empty or still holds the :data:`PLACEHOLDER`, leaves every real value
    untouched, and restricts the file to ``0600``.

    Returns
    -------
    int
        ``0`` on success. ``1`` when the file contained nothing that looked like
        a credential, which almost always means the wrong file was passed.

    Raises
    ------
    SystemExit
        If the target file does not exist. ``make secrets`` copies
        ``.env.example`` into place first, so this only fires on a direct call.

    Notes
    -----
    A line counts as a credential when its name ends in ``_KEY``, ``_SECRET``,
    ``_USER`` or ``_PASSWORD``. Everything else -- ports, endpoints, log levels
    -- is copied through unchanged.

    Only the *names* of the variables touched are printed, never their values.

    The target file and the config file are taken from ``sys.argv``: the first
    argument is the ``.env`` to fill (default ``.env``), the second the
    ``buckets.conf`` to read (default ``bootstrap/buckets.conf`` beside it).
    """
    path = Path(sys.argv[1] if len(sys.argv) > 1 else ".env")
    if not path.exists():
        sys.exit(f"{path} does not exist. Run: cp .env.example .env")

    buckets_conf = (
        Path(sys.argv[2]) if len(sys.argv) > 2 else path.parent / "bootstrap/buckets.conf"
    )
    text = path.read_text()
    present = {
        line.split("=", 1)[0].strip()
        for line in text.splitlines()
        if "=" in line and not line.strip().startswith("#")
    }
    missing = [var for var in required_variables(buckets_conf) if var not in present]
    if missing:
        if not text.endswith("\n"):
            text += "\n"
        text += (
            "\n# Added automatically from bootstrap/buckets.conf. Mirror these into\n"
            "# .env.example (with CHANGE_ME placeholders, never real values).\n"
        )
        text += "".join(f"{var}={PLACEHOLDER}\n" for var in missing)
        path.write_text(text)

    lines = path.read_text().splitlines(keepends=True)
    out: list[str] = []
    filled: list[str] = []
    kept: list[str] = []

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            out.append(line)
            continue
        name, _, value = stripped.partition("=")
        name, value = name.strip(), value.strip()

        is_credential = name.endswith(("_KEY", "_SECRET", "_USER", "_PASSWORD"))
        if not is_credential:
            out.append(line)
            continue

        if PLACEHOLDER not in value and value:
            kept.append(name)
            out.append(line)
            continue

        generated = (
            new_key(name) if name.endswith("_KEY") or name.endswith("_USER") else new_secret()
        )
        out.append(f"{name}={generated}\n")
        filled.append(name)

    path.write_text("".join(out))
    # Owner read/write only. A .env that other users on the box can read is not
    # a secret store, it is a notice board.
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)

    if missing:
        print(
            f"{len(missing)} credential(s) required by buckets.conf were missing and have been added."
        )
    print(f"{path}: {len(filled)} credential(s) generated, {len(kept)} left untouched.")
    if filled:
        print("  generated: " + ", ".join(filled))
    if kept:
        print("  kept (already set): " + ", ".join(kept))
    print(f"\nPermissions set to 0600. {path} is gitignored — keep it that way.")
    if not filled and not kept:
        print("\nNothing looked like a credential. Is this the right file?")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
