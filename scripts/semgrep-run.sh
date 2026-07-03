#!/usr/bin/env bash
# =============================================================================
# scripts/semgrep-run.sh — Orbit Semgrep Canon-Guard engine
#
# Orbit canonical copy (CR-A079-8, extracted from ynetplus
# scripts/council/semgrep-run.sh, CR-A055-1). Logic unchanged; genericized
# for multi-product use by turning the two hardcoded ynetplus paths
# (semgrep/canon rules dir, backend/ scan target) into flags with
# back-compatible defaults. Invoked by .github/workflows/sast-semgrep.yml.
#
# Usage:
#   ./semgrep-run.sh [--mode <full|changed>] [--output-dir <path>]
#                     [--rules-dir <path>] [--scan-path <path>]
#                     [--baseline-file <path>]
#
# Options:
#   --mode full        Scan entire --scan-path tree (default)
#   --mode changed     Scan only git-staged/committed-since-base changed files
#   --output-dir       Override output directory (default: .council/semgrep/)
#   --rules-dir        Semgrep ruleset directory (default: semgrep/canon —
#                       matches the ynetplus convention; other products pass
#                       their own path via the reusable workflow's
#                       `rules_dir` input)
#   --scan-path        Directory tree to scan (default: backend/)
#   --baseline-file    Committed baseline count file to diff against in CI
#                       mode (default: <rules-dir>/baseline-count.txt)
#
# Outputs (written to --output-dir, default .council/semgrep/):
#   findings.json        Machine-readable Semgrep JSON
#   summary.md            Human-readable markdown summary
#   baseline-count.txt    Single integer — total finding count (for CI diff)
#
# CI mode (set SEMGREP_CI=1):
#   Reads baseline count from --baseline-file (committed to the CONSUMER repo).
#   Exits non-zero ONLY if new_findings > baseline_count.
#   Used by .github/workflows/sast-semgrep.yml
#
# Install:
#   pip install semgrep==1.65.0   (Python 3.11 tested pin — see ynetplus
#                                   CI history for the 1.120+/py3.14 metaclass
#                                   bug that motivated pinning to 1.65.0)
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="full"
OUTPUT_DIR="$REPO_ROOT/.council/semgrep"
RULES_DIR="$REPO_ROOT/semgrep/canon"
SCAN_PATH="$REPO_ROOT/backend"
CI_MODE="${SEMGREP_CI:-0}"
BASELINE_FILE=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --rules-dir)
      RULES_DIR="$2"; shift 2 ;;
    --scan-path)
      SCAN_PATH="$2"; shift 2 ;;
    --baseline-file)
      BASELINE_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--mode full|changed] [--output-dir <path>] [--rules-dir <path>] [--scan-path <path>] [--baseline-file <path>]" >&2
      exit 1 ;;
  esac
done

# Default baseline file lives alongside the rules dir unless overridden.
if [ -z "$BASELINE_FILE" ]; then
  BASELINE_FILE="$RULES_DIR/baseline-count.txt"
fi

# ── Verify semgrep is available ───────────────────────────────────────────────
if ! command -v semgrep &>/dev/null; then
  echo "=============================================================="
  echo "ERROR: semgrep not found."
  echo ""
  echo "Install with:"
  echo "  pip install semgrep==1.65.0"
  echo ""
  echo "CI installs via the calling workflow (sast-semgrep.yml)."
  echo "=============================================================="
  exit 1
fi

if [ ! -d "$RULES_DIR" ]; then
  echo "ERROR: rules dir not found: $RULES_DIR" >&2
  echo "Pass --rules-dir <path> pointing at your product's Semgrep ruleset directory." >&2
  exit 1
fi

SEMGREP_VERSION=$(semgrep --version 2>/dev/null || echo "unknown")
echo "=============================================================="
echo "Orbit — Semgrep SAST engine"
echo "semgrep $SEMGREP_VERSION"
echo "=============================================================="
echo ""
echo "Rules:      $RULES_DIR"
echo "Scan path:  $SCAN_PATH"
echo "Output:     $OUTPUT_DIR"
echo "Mode:       $MODE"
echo ""

# ── Prepare output directory ──────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

FINDINGS_JSON="$OUTPUT_DIR/findings.json"
SUMMARY_MD="$OUTPUT_DIR/summary.md"
BASELINE_COUNT_OUT="$OUTPUT_DIR/baseline-count.txt"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Run Semgrep ───────────────────────────────────────────────────────────────
echo "Running Semgrep..."
echo ""

SEMGREP_EXIT=0
if [ "$MODE" = "full" ]; then
  semgrep \
    --config "$RULES_DIR" \
    --json \
    --output "$FINDINGS_JSON" \
    "$SCAN_PATH" \
    2>/dev/null || SEMGREP_EXIT=$?
else
  # Changed-files mode: only scan files touched since last commit
  CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD~1 HEAD 2>/dev/null | grep "\.py$" | tr '\n' ' ' || true)
  if [ -z "$CHANGED_FILES" ]; then
    echo "No changed Python files — skipping scan."
    echo '{"results":[],"errors":[],"version":""}' > "$FINDINGS_JSON"
  else
    # shellcheck disable=SC2086
    semgrep \
      --config "$RULES_DIR" \
      --json \
      --output "$FINDINGS_JSON" \
      $CHANGED_FILES \
      2>/dev/null || SEMGREP_EXIT=$?
  fi
fi

# Semgrep exits 1 on findings found, not on error. Normalize.
if [ "$SEMGREP_EXIT" -gt 1 ]; then
  echo "ERROR: Semgrep exited with code $SEMGREP_EXIT (scan error, not findings)." >&2
  exit "$SEMGREP_EXIT"
fi

# ── Parse findings ────────────────────────────────────────────────────────────
FINDING_COUNT=$(python3 - "$FINDINGS_JSON" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
print(len(data.get("results", [])))
PYEOF
)

echo "$FINDING_COUNT" > "$BASELINE_COUNT_OUT"

echo "Total findings: $FINDING_COUNT"
echo ""

# ── Build human-readable MD summary ──────────────────────────────────────────
python3 - "$FINDINGS_JSON" "$SUMMARY_MD" "$TIMESTAMP" "$FINDING_COUNT" <<'PYEOF'
import json, sys
from collections import defaultdict

data = json.load(open(sys.argv[1]))
out_path = sys.argv[2]
timestamp = sys.argv[3]
total = int(sys.argv[4])

results = data.get("results", [])

by_rule = defaultdict(list)
for r in results:
    rule_id = r.get("check_id", "unknown")
    by_rule[rule_id].append(r)

by_sev = defaultdict(list)
for r in results:
    sev = r.get("extra", {}).get("severity", "UNKNOWN").upper()
    by_sev[sev].append(r)

errors_count = len(by_sev.get("ERROR", []))
warnings_count = len(by_sev.get("WARNING", []))

lines = []
lines.append("# Orbit — Semgrep SAST Baseline")
lines.append("")
lines.append(f"**Generated:** {timestamp}")
lines.append(f"**Total findings:** {total}  ")
lines.append(f"**ERROR:** {errors_count} | **WARNING:** {warnings_count}")
lines.append("")
lines.append("This is the consumer's committed baseline inventory. Each finding is a")
lines.append("ruleset violation that must be remediated before it can be added to the")
lines.append("committed baseline; the gate only blocks NEW violations above baseline.")
lines.append("")

lines.append("## Findings by Rule")
lines.append("")
lines.append("| Rule | Count | Severity |")
lines.append("|------|-------|----------|")
for rule_id, findings in sorted(by_rule.items(), key=lambda x: -len(x[1])):
    short_id = rule_id.split(".")[-1]
    sev = findings[0].get("extra", {}).get("severity", "UNKNOWN").upper()
    lines.append(f"| `{short_id}` | {len(findings)} | {sev} |")

lines.append("")
lines.append("## Finding Details")
lines.append("")

for rule_id, findings in sorted(by_rule.items(), key=lambda x: -len(x[1])):
    short_id = rule_id.split(".")[-1]
    lines.append(f"### {short_id} ({len(findings)} findings)")
    lines.append("")
    lines.append("| File | Line | Code |")
    lines.append("|------|------|------|")
    for f in sorted(findings, key=lambda x: (x.get("path", ""), x.get("start", {}).get("line", 0))):
        path = f.get("path", "?")
        line = f.get("start", {}).get("line", "?")
        code = f.get("extra", {}).get("lines", "").strip().replace("|", "\\|")[:120]
        lines.append(f"| `{path}` | {line} | `{code}` |")
    lines.append("")

lines.append("---")
lines.append("*Generated by `scripts/semgrep-run.sh` — Orbit (ynetplus/orbit)*")

with open(out_path, "w") as fh:
    fh.write("\n".join(lines) + "\n")

print(f"Summary written to {out_path}")
PYEOF

echo ""
echo "Outputs:"
echo "  JSON findings: $FINDINGS_JSON"
echo "  MD summary:    $SUMMARY_MD"
echo "  Baseline count: $BASELINE_COUNT_OUT ($FINDING_COUNT)"
echo ""

# ── CI mode: block on NEW violations only ─────────────────────────────────────
if [ "$CI_MODE" = "1" ]; then
  echo "=============================================================="
  echo "CI MODE: comparing against committed baseline"
  echo "=============================================================="

  if [ ! -f "$BASELINE_FILE" ]; then
    echo "WARNING: No baseline file found at $BASELINE_FILE"
    echo "Committing current count as baseline. Run:"
    echo "  echo $FINDING_COUNT > $BASELINE_FILE"
    echo "  git add $BASELINE_FILE && git commit -m 'chore: semgrep baseline'"
    echo "WARN_NO_BASELINE: $FINDING_COUNT findings (no baseline to compare against)"
    exit 0
  fi

  COMMITTED_BASELINE=$(cat "$BASELINE_FILE" | tr -d '[:space:]')
  echo "Committed baseline: $COMMITTED_BASELINE findings"
  echo "Current scan:       $FINDING_COUNT findings"
  echo ""

  if [ "$FINDING_COUNT" -gt "$COMMITTED_BASELINE" ]; then
    NEW_COUNT=$((FINDING_COUNT - COMMITTED_BASELINE))
    echo "=============================================================="
    echo "BLOCKED: $NEW_COUNT NEW violation(s) introduced!"
    echo "=============================================================="
    echo ""
    echo "The ruleset found $FINDING_COUNT findings in this PR."
    echo "The committed baseline allows $COMMITTED_BASELINE."
    echo ""
    echo "You have introduced $NEW_COUNT new violation(s). Fix them before merging."
    echo ""
    echo "Findings: $SUMMARY_MD"
    echo ""
    cat "$SUMMARY_MD" | head -50
    exit 1
  elif [ "$FINDING_COUNT" -lt "$COMMITTED_BASELINE" ]; then
    FIXED=$((COMMITTED_BASELINE - FINDING_COUNT))
    echo "GREAT: $FIXED violation(s) were fixed in this PR!"
    echo "Update the baseline: echo $FINDING_COUNT > $BASELINE_FILE"
    echo ""
    echo "WARN_BASELINE_STALE: Current=$FINDING_COUNT Baseline=$COMMITTED_BASELINE (update recommended)"
  else
    echo "PASS: No new violations introduced ($FINDING_COUNT = baseline $COMMITTED_BASELINE)."
  fi
  echo ""
fi

echo "=============================================================="
echo "Semgrep scan complete — $FINDING_COUNT finding(s)"
echo "=============================================================="
