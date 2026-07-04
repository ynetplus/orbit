#!/usr/bin/env python3
"""
apply_exclude_globs.py — exclude_globs implementation for secret-detection.yml
(CR-A079-14 Part O / F4 — Third Eye LED-041).

The `exclude_globs` input on secret-detection.yml previously mapped to the
`EXCLUDE_GLOBS` env var but nothing read it (net inert). This script is the
consumer of that input, called from two places in the workflow:

  1. "Determine changed files" (incremental mode) — `filter` subcommand:
     narrows the diffed file list BEFORE it's written to .changed-files.txt
     and handed to detect-secrets via xargs.
  2. "Scan for new secrets" (both modes) — `to-regex` subcommand: translates
     the same glob patterns into Python-regex `--exclude-files` arguments so
     the full-scan (`--all-files`) path also honors exclude_globs, not just
     the incremental path.

Format: `exclude_globs` is a comma- and/or whitespace-separated (including
newlines) list of shell-style glob patterns, matched with `fnmatch` against
the full repo-relative path — `*` matches across `/` (it is a plain string
glob, not a path-segment glob), so `fixtures/secrets/excluded/*` matches
`fixtures/secrets/excluded/anything/nested.txt` too. Patterns are ADDITIVE to
the built-in excludes (.secrets.baseline, .env, .env.example, *.lock, .git/)
— they can only exclude MORE, never un-exclude a built-in.

Over-widening guards (fail loudly, exit 1, never silently scan nothing):
  - A literal `*` or `**` pattern is rejected outright — this is almost
    always a copy-paste mistake that would exempt the ENTIRE repo from
    secret scanning, which defeats the gate's purpose.
  - If the glob(s) — even ones that aren't literally `*` — would exclude
    EVERY candidate file in this scan (and there was at least one candidate
    before exclusion), that's the same failure mode via a less obvious
    pattern (e.g. several globs that jointly cover everything touched by a
    given PR). Rejected the same way.

Usage:
    # subcommand 1: filter a candidate file list (one path per line on stdin)
    cat candidates.txt | python3 apply_exclude_globs.py filter "<exclude_globs>"

    # subcommand 2: translate patterns to --exclude-files regex args (one per line)
    python3 apply_exclude_globs.py to-regex "<exclude_globs>"

Exit codes:
    0 — success (filtered list / regex list written to stdout)
    1 — guard tripped; explanation on stderr (prefixed `::error::` for GitHub
        Actions annotations), nothing meaningful written to stdout
"""
import fnmatch
import sys


def parse_patterns(raw: str) -> list[str]:
    """Split on commas and/or any whitespace (space, tab, newline)."""
    if not raw or not raw.strip():
        return []
    parts: list[str] = []
    for chunk in raw.replace(",", " ").split():
        chunk = chunk.strip()
        if chunk:
            parts.append(chunk)
    return parts


def _reject_bare_wildcard(patterns: list[str]) -> str | None:
    for p in patterns:
        if p in ("*", "**"):
            return (
                f"::error::exclude_globs contains a bare '{p}' pattern, which would "
                "exempt EVERY file from secret scanning. Refusing to run (over-widening "
                "guard, not a bug). Use a specific path glob instead, e.g. "
                "'vendor/**/*.lock' or 'fixtures/secrets/excluded/*'."
            )
    return None


def cmd_filter(raw_globs: str, candidates: list[str]) -> tuple[int, list[str]]:
    patterns = parse_patterns(raw_globs)

    err = _reject_bare_wildcard(patterns)
    if err:
        print(err, file=sys.stderr)
        return 1, []

    if not patterns:
        return 0, candidates

    if not candidates:
        # Nothing to scan even before exclusion — nothing to guard against.
        return 0, []

    survivors = [
        f for f in candidates
        if not any(fnmatch.fnmatch(f, pat) for pat in patterns)
    ]

    if not survivors:
        shown = ", ".join(candidates[:10])
        more = "…" if len(candidates) > 10 else ""
        print(
            "::error::exclude_globs excludes ALL "
            f"{len(candidates)} candidate file(s) for this scan ({shown}{more}). "
            "Refusing to run — this would silently disable secret detection for the "
            "entire scan. Narrow exclude_globs so at least one candidate file remains "
            "scannable.",
            file=sys.stderr,
        )
        return 1, []

    return 0, survivors


def cmd_to_regex(raw_globs: str) -> tuple[int, list[str]]:
    patterns = parse_patterns(raw_globs)

    err = _reject_bare_wildcard(patterns)
    if err:
        print(err, file=sys.stderr)
        return 1, []

    if not patterns:
        return 0, []

    regexes = []
    for pat in patterns:
        # fnmatch.translate() yields e.g. "(?s:foo/bar/.*)\\Z" — detect-secrets'
        # --exclude-files applies each value as a Python re.search() pattern
        # against the candidate filename, so this round-trips correctly.
        regexes.append(fnmatch.translate(pat))
    return 0, regexes


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "Usage: apply_exclude_globs.py <filter|to-regex> <exclude_globs> "
            "[< candidates.txt]",
            file=sys.stderr,
        )
        return 2

    subcommand, raw_globs = argv[0], argv[1]

    if subcommand == "filter":
        candidates = [line.rstrip("\n") for line in sys.stdin if line.strip()]
        code, out = cmd_filter(raw_globs, candidates)
    elif subcommand == "to-regex":
        code, out = cmd_to_regex(raw_globs)
    else:
        print(f"Unknown subcommand: {subcommand!r} (expected 'filter' or 'to-regex')", file=sys.stderr)
        return 2

    for line in out:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
