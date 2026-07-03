#!/usr/bin/env python3
"""
check_migration_lock_risk.py — Migration Lock-Risk Analyzer

Orbit canonical copy (CR-A079-8, extracted from ynetplus CR-A078-14, logic
unchanged — already product-agnostic: takes file paths as argv, no hardcoded
product paths). Invoked by .github/workflows/migration-lock-risk.yml.

Scans new Alembic migration files for DDL patterns that acquire long-held
PostgreSQL locks on production tables. Used as a WARN gate in CI — always
exits 0 regardless of findings. Engineers review warnings before merging.

Motivation:
    GoCardless 15-second outage: a migration added an index without CONCURRENTLY.
    PostgreSQL queued every subsequent DML/SELECT behind the pending lock request.
    Reference: RN-019 §3, GoCardless post-mortem 2024.

Usage:
    python3 check_migration_lock_risk.py <file1.py> [file2.py ...]

Suppression (per-line):
    Add "# LOCK-RISK: ACCEPTED — <reason>" on the line immediately BEFORE
    the flagged op.* call to suppress that specific warning.
    A reason after the em-dash is expected but not enforced; bare suppression still works.

Exit codes:
    0 always (WARN gate — never hard-blocks CI)
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Pattern definitions
# ---------------------------------------------------------------------------

@dataclass
class RiskPattern:
    name: str
    regex: re.Pattern
    risk: str
    fix: str
    reference: str = "RN-019 §3, GoCardless post-mortem 2024"

    def check_line(self, line: str) -> bool:
        return bool(self.regex.search(line))


# Patterns flagged as risky DDL:
#   1. op.create_index() without postgresql_concurrently=True  → ShareLock
#   2. op.alter_column() with nullable=False                   → AccessExclusiveLock
#   3. op.alter_column() with type_=                           → full table rewrite
#   4. op.add_column() nullable=False without server_default   → full rewrite / scan
#   5. op.add_constraint() or op.create_foreign_key()          → full table scan
#   6. op.drop_table()                                         → AccessExclusiveLock
#   7. op.execute() with raw ALTER TABLE                       → manual review required

_SIMPLE_PATTERNS: list[RiskPattern] = [
    RiskPattern(
        name="alter_column_nullable_false",
        regex=re.compile(r"\bop\.alter_column\s*\(.*nullable\s*=\s*False"),
        risk="AccessExclusiveLock — SET NOT NULL requires full table scan to validate constraint",
        fix=(
            "Two-phase approach:\n"
            "         (1) ADD CONSTRAINT ... CHECK (col IS NOT NULL) NOT VALID\n"
            "         (2) VALIDATE CONSTRAINT (acquires ShareUpdateExclusiveLock only — non-blocking)"
        ),
    ),
    RiskPattern(
        name="alter_column_type_change",
        regex=re.compile(r"\bop\.alter_column\s*\(.*\btype_\s*="),
        risk="AccessExclusiveLock — column type change triggers full table rewrite",
        fix=(
            "Multi-migration approach:\n"
            "         (1) Add new column (nullable)\n"
            "         (2) Backfill new column\n"
            "         (3) Rename old->old_deprecated, new->canonical\n"
            "         (4) Drop old column in a separate deploy cycle"
        ),
    ),
    RiskPattern(
        name="add_constraint_or_foreign_key",
        regex=re.compile(r"\b(op\.add_constraint|op\.create_foreign_key)\s*\("),
        risk="AccessExclusiveLock — ADD CONSTRAINT validates immediately (full table scan). FK without NOT VALID scans whole table",
        fix=(
            "Use NOT VALID option to skip immediate validation, then:\n"
            "         VALIDATE CONSTRAINT in a separate step (ShareUpdateExclusiveLock — non-blocking)"
        ),
    ),
    RiskPattern(
        name="drop_table",
        regex=re.compile(r"\bop\.drop_table\s*\("),
        risk="AccessExclusiveLock — DROP TABLE destroys all indexes and blocks all concurrent access",
        fix=(
            "Safe on empty/test tables.\n"
            "         On production tables: ensure no FK references exist first,\n"
            "         confirm zero traffic, deploy outside business hours."
        ),
    ),
]

SUPPRESSION_MARKER = "# LOCK-RISK: ACCEPTED"


def _is_suppressed(prev_line: Optional[str]) -> bool:
    """Return True if the immediately preceding non-blank line contains the suppression marker."""
    if prev_line is None:
        return False
    return SUPPRESSION_MARKER in prev_line


# ---------------------------------------------------------------------------
# Per-file scanner
# ---------------------------------------------------------------------------

@dataclass
class Finding:
    lineno: int
    line_text: str
    pattern: RiskPattern


def _check_create_index(stripped: str) -> bool:
    """Flag op.create_index() only when postgresql_concurrently=True is absent."""
    if not re.search(r"\bop\.create_index\s*\(", stripped):
        return False
    has_concurrent = (
        "postgresql_concurrently=True" in stripped
        or "postgresql_concurrently = True" in stripped
    )
    return not has_concurrent


CREATE_INDEX_PATTERN = RiskPattern(
    name="create_index_without_concurrently",
    regex=re.compile(r"\bop\.create_index\s*\("),
    risk="ShareLock — CREATE INDEX without CONCURRENTLY blocks writes for full index build duration",
    fix=(
        "Add postgresql_concurrently=True to op.create_index()\n"
        "         Note: CONCURRENTLY cannot run inside a transaction block.\n"
        "         Use op.execute(\"CREATE INDEX CONCURRENTLY ...\") or split into two migrations."
    ),
)

RAW_ALTER_PATTERN = RiskPattern(
    name="raw_alter_table_in_execute",
    regex=re.compile(r"\bop\.execute\s*\("),
    risk="Raw ALTER TABLE inside op.execute() — lock class depends on the specific statement (manual review required)",
    fix=(
        "Review the ALTER TABLE statement for its lock class.\n"
        "         Prefer Alembic op.* helpers (they document lock behavior).\n"
        "         If unavoidable, add '# LOCK-RISK: ACCEPTED — <reason>' above the line."
    ),
)

ADD_COLUMN_PATTERN = RiskPattern(
    name="add_column_nullable_false_no_default",
    regex=re.compile(r"\bop\.add_column\s*\("),
    risk="AccessExclusiveLock — adding NOT NULL column without server_default requires full table scan (Pg <15 rewrites; Pg 15+ still validates)",
    fix=(
        "Add server_default=sa.text(\"'value'\") to the column definition,\n"
        "         or use a nullable column + backfill + separate NOT NULL constraint."
    ),
)


def _check_raw_alter_table(stripped: str) -> bool:
    if not re.search(r"\bop\.execute\s*\(", stripped):
        return False
    return bool(re.search(r"ALTER\s+TABLE", stripped, re.IGNORECASE))


def _check_add_column_risky(stripped: str, window: list[str]) -> bool:
    """
    Flag op.add_column() with nullable=False and no server_default.
    Looks at up to 3 preceding lines + current line as context window.
    """
    if not re.search(r"\bop\.add_column\s*\(", stripped):
        return False
    context = "".join(window[-3:]) + stripped
    has_nullable_false = bool(re.search(r"nullable\s*=\s*False", context))
    has_server_default = bool(re.search(r"server_default\s*=", context))
    return has_nullable_false and not has_server_default


def scan_file(filepath: str) -> list[Finding]:
    """Scan a single migration file and return all findings."""
    path = Path(filepath)
    if not path.exists():
        print(f"  [WARN] File not found: {filepath}")
        return []

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception as exc:
        print(f"  [WARN] Cannot read {filepath}: {exc}")
        return []

    findings: list[Finding] = []
    prev_line: Optional[str] = None
    accumulated: list[str] = []

    for lineno, raw_line in enumerate(lines, start=1):
        stripped = raw_line.strip()

        # 1. CREATE INDEX without CONCURRENTLY
        if _check_create_index(stripped):
            if not _is_suppressed(prev_line):
                findings.append(Finding(lineno, raw_line, CREATE_INDEX_PATTERN))

        # 2 & 3. alter_column (nullable=False, type_=)
        for pattern in _SIMPLE_PATTERNS:
            if pattern.name in ("alter_column_nullable_false", "alter_column_type_change",
                                "add_constraint_or_foreign_key", "drop_table"):
                if pattern.check_line(stripped):
                    if not _is_suppressed(prev_line):
                        findings.append(Finding(lineno, raw_line, pattern))

        # 4. op.add_column with nullable=False and no server_default
        if _check_add_column_risky(stripped, accumulated):
            if not _is_suppressed(prev_line):
                findings.append(Finding(lineno, raw_line, ADD_COLUMN_PATTERN))

        # 7. Raw ALTER TABLE in op.execute()
        if _check_raw_alter_table(stripped):
            if not _is_suppressed(prev_line):
                findings.append(Finding(lineno, raw_line, RAW_ALTER_PATTERN))

        accumulated.append(stripped)
        if stripped:
            prev_line = stripped

    return findings


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def print_findings(filepath: str, findings: list[Finding]) -> None:
    print(f"\n{'=' * 62}")
    print(f"WARNING  LOCK-RISK WARNING: {filepath}")
    print(f"{'=' * 62}")
    for f in findings:
        print(f"   Line {f.lineno}: {f.line_text.rstrip()}")
        print(f"   Risk: {f.pattern.risk}")
        print(f"   Fix:  {f.pattern.fix}")
        print(f"   Reference: {f.pattern.reference}")
        print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    if not argv:
        print("Usage: check_migration_lock_risk.py <file1.py> [file2.py ...]")
        print("Exit code is always 0 (WARN gate only).")
        return 0

    total_files = len(argv)
    all_findings: dict[str, list[Finding]] = {}

    for filepath in argv:
        findings = scan_file(filepath)
        if findings:
            all_findings[filepath] = findings

    if not all_findings:
        print(f"No lock-risk patterns detected in {total_files} file(s).")
        return 0

    for filepath, findings in all_findings.items():
        print_findings(filepath, findings)

    total_findings = sum(len(f) for f in all_findings.values())
    print(f"\n{'=' * 62}")
    print(f"WARNING  ACTION REQUIRED: {total_findings} lock-risk pattern(s) found.")
    print(f"    Review warnings above before merging.")
    print(f"")
    print(f"    Safe to ignore for:")
    print(f"      - Brand-new tables with 0 rows")
    print(f"      - Tables with <~10k rows + off-hours deploy")
    print(f"")
    print(f"    Suppress per-line: add the following on the line BEFORE the op call:")
    print(f"      # LOCK-RISK: ACCEPTED -- <reason>")
    print(f"{'=' * 62}\n")

    # Always exit 0 — WARN gate only, never hard-blocks CI
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
