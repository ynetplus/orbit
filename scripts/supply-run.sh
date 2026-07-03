#!/usr/bin/env bash
# =============================================================================
# scripts/supply-run.sh — Orbit Supply-Chain (Trivy + pip-audit) engine
#
# Orbit canonical copy (CR-A079-8, extracted from ynetplus
# scripts/council/supply-run.sh, CR-A055-2/6, CR-A078-3). Logic unchanged;
# genericized for multi-product use by turning the hardcoded ynetplus paths
# (backend/, infrastructure/, backend/requirements*.txt) into flags with
# back-compatible defaults. Invoked by .github/workflows/supply-audit.yml.
#
# Usage:
#   ./supply-run.sh [--output-dir <path>] [--lane <trivy|pip-audit|all>]
#                    [--baseline-file <path>] [--backend-path <path>]
#                    [--infra-path <path>] [--requirements-glob <glob>]
#
# Options:
#   --output-dir       Override output directory (default: .council/supply/)
#   --lane             Which sub-scans to run: trivy | pip-audit | all (default: all)
#   --baseline-file    Committed baseline file to diff against in CI mode
#                       (default: supply/baseline-count.txt)
#   --backend-path     Directory trivy fs scans for dependency vulns
#                       (default: backend/)
#   --infra-path       Directory trivy config scans for IaC misconfigs
#                       (default: infrastructure/)
#   --requirements-glob  Space-separated list of requirements*.txt files for
#                       pip-audit (default: backend/requirements.txt
#                       backend/requirements-dev.txt backend/requirements-lambda.txt)
#
# Outputs (written to --output-dir, default .council/supply/):
#   findings.json        Machine-readable combined findings
#   summary.md           Human-readable markdown summary
#   baseline-count.txt   Single integer -- total finding count for the lanes that ran
#
# CI mode (set SUPPLY_CI=1):
#   Reads baseline count from --baseline-file (committed to the CONSUMER repo).
#   Exits non-zero ONLY if new_findings > baseline_count.
#   Used by .github/workflows/supply-audit.yml
#
# Token-gated Snyk (OPTIONAL -- functional baseline does NOT require it):
#   If $SNYK_TOKEN is set in the environment, snyk test + snyk iac test
#   will run and their results will be merged into the findings.
#   If unset, Snyk is silently skipped (one informational log line).
#   NEVER echo or log the token value itself.
#   NOTE: Snyk only runs when LANE=all (it is not split into a standalone lane).
#
# Install (no-account functional baseline):
#   pip install pip-audit==2.7.3
#   brew install trivy    # or: https://aquasecurity.github.io/trivy/
# =============================================================================

set -euo pipefail

# -- Defaults -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/.council/supply"
CI_MODE="${SUPPLY_CI:-0}"
LANE="all"
BASELINE_FILE="$REPO_ROOT/supply/baseline-count.txt"
BACKEND_PATH="$REPO_ROOT/backend"
INFRA_PATH="$REPO_ROOT/infrastructure"
REQUIREMENTS_GLOB=""

# -- Argument parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --lane)
      LANE="$2"
      if [[ "$LANE" != "all" && "$LANE" != "trivy" && "$LANE" != "pip-audit" ]]; then
        echo "Unknown --lane value: $LANE" >&2
        echo "Valid values: all, trivy, pip-audit" >&2
        exit 1
      fi
      shift 2 ;;
    --baseline-file)
      BASELINE_FILE="$2"; shift 2 ;;
    --backend-path)
      BACKEND_PATH="$2"; shift 2 ;;
    --infra-path)
      INFRA_PATH="$2"; shift 2 ;;
    --requirements-glob)
      REQUIREMENTS_GLOB="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--output-dir <path>] [--lane <trivy|pip-audit|all>] [--baseline-file <path>] [--backend-path <path>] [--infra-path <path>] [--requirements-glob <glob>]" >&2
      exit 1 ;;
  esac
done

# -- Derive which sub-scans this invocation should run -----------------------
RUN_PIP_AUDIT=0
RUN_TRIVY=0
if [[ "$LANE" == "all" || "$LANE" == "pip-audit" ]]; then
  RUN_PIP_AUDIT=1
fi
if [[ "$LANE" == "all" || "$LANE" == "trivy" ]]; then
  RUN_TRIVY=1
fi

# -- Tool availability checks --------------------------------------------------
# pip-audit: best-effort -- missing binary is a soft warning, not a hard abort.
# Trivy is the lane carrier; if trivy is missing AND we need it, that is a hard error.
PIP_AUDIT_SKIPPED=0

if [ "$RUN_PIP_AUDIT" = "1" ]; then
  if ! command -v pip-audit &>/dev/null; then
    echo "WARN: pip-audit not found -- skipping (trivy continues)."
    echo "      Install: pip install pip-audit==2.7.3"
    PIP_AUDIT_SKIPPED=1
  fi
fi

if [ "$RUN_TRIVY" = "1" ]; then
  if ! command -v trivy &>/dev/null; then
    echo "=============================================================="
    echo "ERROR: trivy not found."
    echo ""
    echo "Install with:"
    echo "  brew install trivy                     # macOS"
    echo "  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v0.71.0"
    echo ""
    echo "Pinned version: 0.71.0 (see .github/workflows/supply-audit.yml)"
    echo "=============================================================="
    exit 1
  fi
fi

PIP_AUDIT_VERSION="n/a (skipped or lane=trivy)"
if [ "$RUN_PIP_AUDIT" = "1" ] && [ "$PIP_AUDIT_SKIPPED" = "0" ]; then
  PIP_AUDIT_VERSION=$(pip-audit --version 2>/dev/null | head -1 || echo "unknown")
fi
TRIVY_VERSION="n/a (lane=pip-audit)"
if [ "$RUN_TRIVY" = "1" ]; then
  TRIVY_VERSION=$(trivy --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
fi

echo "=============================================================="
echo "Orbit -- Supply-Chain engine"
echo "lane=${LANE} | pip-audit ${PIP_AUDIT_VERSION} | trivy ${TRIVY_VERSION}"
echo "=============================================================="
echo ""
echo "Output:       $OUTPUT_DIR"
echo "Lane:         $LANE"
echo "Backend path: $BACKEND_PATH"
echo "Infra path:   $INFRA_PATH"
echo ""

# -- Prepare output directory --------------------------------------------------
mkdir -p "$OUTPUT_DIR"

FINDINGS_JSON="$OUTPUT_DIR/findings.json"
SUMMARY_MD="$OUTPUT_DIR/summary.md"
BASELINE_COUNT_OUT="$OUTPUT_DIR/baseline-count.txt"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# -- Temporary work files ------------------------------------------------------
TMP_PIP_AUDIT="$OUTPUT_DIR/_pip_audit_raw.json"
TMP_TRIVY_IAC="$OUTPUT_DIR/_trivy_iac_raw.json"
TMP_TRIVY_FS="$OUTPUT_DIR/_trivy_fs_raw.json"
TMP_SNYK_DEPS="$OUTPUT_DIR/_snyk_deps_raw.json"
TMP_SNYK_IAC="$OUTPUT_DIR/_snyk_iac_raw.json"

echo '{"dependencies":[]}' > "$TMP_PIP_AUDIT"
echo '{"Results":[]}' > "$TMP_TRIVY_IAC"
echo '{"Results":[]}' > "$TMP_TRIVY_FS"
echo '{}' > "$TMP_SNYK_DEPS"
echo '{}' > "$TMP_SNYK_IAC"

# -- 1. pip-audit SCA scan (best-effort; runs when lane=all or lane=pip-audit) -
PIP_VULN_COUNT=0

if [ "$RUN_PIP_AUDIT" = "1" ]; then
  echo ">>> pip-audit: scanning Python dependencies..."
  echo ""

  if [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
    echo "    WARN: pip-audit unavailable in this env -- skipping (trivy continues)"
    echo ""
  else
    PIP_AUDIT_RUN_EXIT=0

    REQ_FILES=()
    if [ -n "$REQUIREMENTS_GLOB" ]; then
      for req in $REQUIREMENTS_GLOB; do
        [ -f "$req" ] && REQ_FILES+=("-r" "$req")
      done
    else
      for req in \
          "$BACKEND_PATH/requirements.txt" \
          "$BACKEND_PATH/requirements-dev.txt" \
          "$BACKEND_PATH/requirements-lambda.txt"; do
        [ -f "$req" ] && REQ_FILES+=("-r" "$req")
      done
    fi

    if [ ${#REQ_FILES[@]} -eq 0 ]; then
      echo "    WARN: No requirements*.txt found -- skipping pip-audit." >&2
      echo '{"dependencies":[]}' > "$TMP_PIP_AUDIT"
    else
      pip-audit "${REQ_FILES[@]}" --format json --output "$TMP_PIP_AUDIT" 2>/dev/null \
        || PIP_AUDIT_RUN_EXIT=$?

      if [ "$PIP_AUDIT_RUN_EXIT" -gt 1 ]; then
        echo "    WARN: pip-audit unavailable in this env -- skipping (trivy continues)" >&2
        echo "    (exit code $PIP_AUDIT_RUN_EXIT -- env error, not findings)" >&2
        PIP_AUDIT_SKIPPED=1
      fi
    fi

    if [ "$PIP_AUDIT_SKIPPED" = "0" ] && [ ! -f "$TMP_PIP_AUDIT" ]; then
      echo "    WARN: pip-audit unavailable in this env -- _pip_audit_raw.json not produced -- skipping (trivy continues)" >&2
      PIP_AUDIT_SKIPPED=1
    fi

    if [ "$PIP_AUDIT_SKIPPED" = "0" ]; then
      PIP_VULN_COUNT=$(python3 - "$TMP_PIP_AUDIT" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
total = sum(len(dep.get("vulns", [])) for dep in data.get("dependencies", []))
print(total)
PYEOF
)
      echo "    pip-audit: $PIP_VULN_COUNT vulnerability finding(s)"
      echo ""
    fi
  fi
else
  echo ">>> pip-audit: skipped (lane=$LANE)"
  echo ""
fi

if [ "$RUN_PIP_AUDIT" = "0" ] || [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
  echo '{"dependencies":[]}' > "$TMP_PIP_AUDIT"
fi

# -- 2. Trivy IaC config scan (runs when lane=all or lane=trivy) ---------------
TRIVY_IAC_COUNT=0
TRIVY_OK=1

if [ "$RUN_TRIVY" = "1" ]; then
  echo ">>> trivy config: scanning IaC for misconfigurations..."
  echo ""

  TRIVY_IAC_EXIT=0
  if [ -d "$INFRA_PATH" ]; then
    trivy config "$INFRA_PATH" \
      --format json \
      --output "$TMP_TRIVY_IAC" \
      --quiet \
      2>/dev/null || TRIVY_IAC_EXIT=$?
  else
    echo "    NOTE: infra path not found ($INFRA_PATH) -- 0 IaC findings."
  fi

  if [ "$TRIVY_IAC_EXIT" -gt 1 ]; then
    echo "ERROR: trivy config exited with code $TRIVY_IAC_EXIT (scan error, not findings)." >&2
    TRIVY_OK=0
  fi

  if [ "$TRIVY_OK" = "1" ]; then
    TRIVY_IAC_COUNT=$(python3 - "$TMP_TRIVY_IAC" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
total = sum(len(r.get("Misconfigurations", [])) for r in data.get("Results", []))
print(total)
PYEOF
)
    echo "    trivy config: $TRIVY_IAC_COUNT IaC misconfiguration finding(s)"
    echo ""
  fi
else
  echo ">>> trivy config: skipped (lane=$LANE)"
  echo ""
fi

# -- 3. Trivy FS dependency scan (runs when lane=all or lane=trivy) ------------
TRIVY_FS_COUNT=0

if [ "$RUN_TRIVY" = "1" ]; then
  echo ">>> trivy fs: scanning $BACKEND_PATH for dependency vulnerabilities..."
  echo ""

  TRIVY_FS_EXIT=0
  if [ -d "$BACKEND_PATH" ]; then
    trivy fs "$BACKEND_PATH" \
      --scanners vuln \
      --format json \
      --output "$TMP_TRIVY_FS" \
      --quiet \
      2>/dev/null || TRIVY_FS_EXIT=$?
  else
    echo "    NOTE: backend path not found ($BACKEND_PATH) -- 0 dependency findings."
  fi

  if [ "$TRIVY_FS_EXIT" -gt 1 ]; then
    echo "ERROR: trivy fs exited with code $TRIVY_FS_EXIT (scan error, not findings)." >&2
    TRIVY_OK=0
  fi

  if [ "$TRIVY_OK" = "1" ]; then
    TRIVY_FS_COUNT=$(python3 - "$TMP_TRIVY_FS" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
total = sum(len(r.get("Vulnerabilities", [])) for r in data.get("Results", []))
print(total)
PYEOF
)
    echo "    trivy fs: $TRIVY_FS_COUNT dependency vulnerability finding(s)"
    echo ""
  fi
else
  echo ">>> trivy fs: skipped (lane=$LANE)"
  echo ""
fi

# -- Advisor exit guard --------------------------------------------------------
if [ "$RUN_TRIVY" = "1" ] && [ "$TRIVY_OK" = "0" ]; then
  if [ "$RUN_PIP_AUDIT" = "1" ] && [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
    echo "ERROR: pip-audit was skipped AND trivy failed -- supply advisor has no findings to report." >&2
  else
    echo "ERROR: trivy scan failed (pip-audit ran but trivy is the lane carrier)." >&2
  fi
  exit 1
fi

# -- 4. Token-gated Snyk block (OPTIONAL -- only runs when lane=all) ----------
SNYK_DEPS_COUNT=0
SNYK_IAC_COUNT=0
SNYK_RAN=0

if [ "$LANE" = "all" ]; then
  if [ -z "${SNYK_TOKEN:-}" ]; then
    echo ">>> Snyk upgrade available -- set SNYK_TOKEN to activate premium autofix + MCP."
    echo "    (Skipping Snyk -- no token present)"
    echo ""
  else
    if ! command -v snyk &>/dev/null; then
      echo "WARNING: SNYK_TOKEN is set but snyk CLI not found." >&2
      echo "Install: npm install -g snyk" >&2
    else
      echo ">>> snyk test: scanning Python deps..."
      SNYK_DEPS_EXIT=0
      SNYK_TOKEN="${SNYK_TOKEN}" snyk test \
        --file="$BACKEND_PATH/requirements.txt" \
        --package-manager=pip \
        --json > "$TMP_SNYK_DEPS" 2>/dev/null || SNYK_DEPS_EXIT=$?

      echo ">>> snyk iac test: scanning IaC..."
      SNYK_IAC_EXIT=0
      SNYK_TOKEN="${SNYK_TOKEN}" snyk iac test \
        "$INFRA_PATH" \
        --json > "$TMP_SNYK_IAC" 2>/dev/null || SNYK_IAC_EXIT=$?

      SNYK_DEPS_COUNT=$(python3 - "$TMP_SNYK_DEPS" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    vulns = data.get("vulnerabilities", [])
    print(len(vulns))
except Exception:
    print(0)
PYEOF
)
      SNYK_IAC_COUNT=$(python3 - "$TMP_SNYK_IAC" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    issues = data.get("infrastructureAsCodeIssues", [])
    print(len(issues))
except Exception:
    print(0)
PYEOF
)
      SNYK_RAN=1
      echo "    snyk test: $SNYK_DEPS_COUNT dep vulnerability finding(s)"
      echo "    snyk iac:  $SNYK_IAC_COUNT IaC finding(s)"
      echo ""
    fi
  fi
fi

# -- 5. Aggregate totals -------------------------------------------------------
BASE_TOTAL=$((PIP_VULN_COUNT + TRIVY_IAC_COUNT + TRIVY_FS_COUNT))
TOTAL_WITH_SNYK=$((BASE_TOTAL + SNYK_DEPS_COUNT + SNYK_IAC_COUNT))

echo "$BASE_TOTAL" > "$BASELINE_COUNT_OUT"

if [ "$LANE" = "trivy" ]; then
  echo "Total findings (trivy only -- trivy-iac + trivy-fs): $BASE_TOTAL"
elif [ "$LANE" = "pip-audit" ]; then
  if [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
    echo "Total findings (pip-audit lane -- skipped in this env): $BASE_TOTAL"
  else
    echo "Total findings (pip-audit only): $BASE_TOTAL"
  fi
else
  if [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
    echo "Total findings (primary -- trivy only; pip-audit skipped): $BASE_TOTAL"
  else
    echo "Total findings (primary -- pip-audit + trivy): $BASE_TOTAL"
  fi
fi
if [ "$SNYK_RAN" = "1" ]; then
  echo "Total findings (with Snyk premium):           $TOTAL_WITH_SNYK"
fi
echo ""

# -- 6. Build combined findings.json -------------------------------------------
python3 - \
  "$TMP_PIP_AUDIT" "$TMP_TRIVY_IAC" "$TMP_TRIVY_FS" \
  "$TMP_SNYK_DEPS" "$TMP_SNYK_IAC" \
  "$FINDINGS_JSON" "$TIMESTAMP" "$BASE_TOTAL" "$SNYK_RAN" "$PIP_AUDIT_SKIPPED" \
  "$RUN_PIP_AUDIT" "$RUN_TRIVY" "$LANE" \
  <<'PYEOF'
import json, sys

pip_audit_file      = sys.argv[1]
trivy_iac_file      = sys.argv[2]
trivy_fs_file       = sys.argv[3]
snyk_deps_file      = sys.argv[4]
snyk_iac_file       = sys.argv[5]
out_path            = sys.argv[6]
timestamp           = sys.argv[7]
base_total          = int(sys.argv[8])
snyk_ran            = sys.argv[9] == "1"
pip_audit_skipped   = sys.argv[10] == "1"
run_pip_audit       = sys.argv[11] == "1"
run_trivy           = sys.argv[12] == "1"
lane                = sys.argv[13]

pip_data  = json.load(open(pip_audit_file))
trivy_iac = json.load(open(trivy_iac_file))
trivy_fs  = json.load(open(trivy_fs_file))

try:
    snyk_deps = json.load(open(snyk_deps_file))
except Exception:
    snyk_deps = {}
try:
    snyk_iac = json.load(open(snyk_iac_file))
except Exception:
    snyk_iac = {}

pip_findings = []
if run_pip_audit and not pip_audit_skipped:
    for dep in pip_data.get("dependencies", []):
        for vuln in dep.get("vulns", []):
            pip_findings.append({
                "tool": "pip-audit",
                "category": "SCA",
                "id": vuln["id"],
                "package": dep["name"],
                "version": dep["version"],
                "fix_versions": vuln.get("fix_versions", []),
                "description": vuln.get("description", "")[:200],
                "severity": "UNKNOWN",
                "aliases": vuln.get("aliases", []),
            })

trivy_iac_findings = []
if run_trivy:
    for result in trivy_iac.get("Results", []):
        target = result.get("Target", "?")
        for m in result.get("Misconfigurations", []):
            trivy_iac_findings.append({
                "tool": "trivy-config",
                "category": "IaC",
                "id": m.get("AVDID", m.get("ID", "?")),
                "target": target,
                "title": m.get("Title", ""),
                "description": m.get("Description", "")[:200],
                "severity": m.get("Severity", "UNKNOWN"),
                "resolution": m.get("Resolution", ""),
                "references": m.get("References", [])[:3],
            })

trivy_fs_findings = []
if run_trivy:
    for result in trivy_fs.get("Results", []):
        target = result.get("Target", "?")
        for v in result.get("Vulnerabilities", []):
            trivy_fs_findings.append({
                "tool": "trivy-fs",
                "category": "SCA",
                "id": v.get("VulnerabilityID", "?"),
                "package": v.get("PkgName", "?"),
                "installed_version": v.get("InstalledVersion", "?"),
                "fixed_version": v.get("FixedVersion", ""),
                "title": v.get("Title", ""),
                "severity": v.get("Severity", "UNKNOWN"),
                "description": v.get("Description", "")[:200],
            })

snyk_dep_findings = []
if snyk_ran:
    for v in snyk_deps.get("vulnerabilities", []):
        snyk_dep_findings.append({
            "tool": "snyk-test",
            "category": "SCA",
            "id": v.get("id", "?"),
            "package": v.get("packageName", "?"),
            "version": v.get("version", "?"),
            "title": v.get("title", ""),
            "severity": v.get("severity", "UNKNOWN").upper(),
            "description": v.get("description", "")[:200],
        })

snyk_iac_findings = []
if snyk_ran:
    for issue in snyk_iac.get("infrastructureAsCodeIssues", []):
        snyk_iac_findings.append({
            "tool": "snyk-iac",
            "category": "IaC",
            "id": issue.get("id", "?"),
            "title": issue.get("title", ""),
            "severity": issue.get("severity", "UNKNOWN").upper(),
            "description": issue.get("description", "")[:200],
        })

combined = {
    "schema_version": "1.0",
    "generated_at": timestamp,
    "advisor": "supply",
    "lane": lane,
    "baseline_total": base_total,
    "snyk_present": snyk_ran,
    "pip_audit": "not in lane" if not run_pip_audit else ("skipped (env)" if pip_audit_skipped else "ran"),
    "trivy": "not in lane" if not run_trivy else "ran",
    "summary": {
        "pip_audit_vulns": len(pip_findings),
        "pip_audit_status": "not in lane" if not run_pip_audit else ("skipped" if pip_audit_skipped else "ran"),
        "trivy_iac_misconfigs": len(trivy_iac_findings),
        "trivy_fs_vulns": len(trivy_fs_findings),
        "snyk_dep_vulns": len(snyk_dep_findings),
        "snyk_iac_issues": len(snyk_iac_findings),
    },
    "findings": pip_findings + trivy_iac_findings + trivy_fs_findings
               + snyk_dep_findings + snyk_iac_findings,
}

with open(out_path, "w") as fh:
    json.dump(combined, fh, indent=2)

print(f"Combined findings JSON written to {out_path}")
PYEOF

# -- 7. Build human-readable MD summary ----------------------------------------
python3 - "$FINDINGS_JSON" "$SUMMARY_MD" "$TIMESTAMP" "$BASE_TOTAL" "$SNYK_RAN" "$PIP_AUDIT_SKIPPED" "$RUN_PIP_AUDIT" "$RUN_TRIVY" "$LANE" <<'PYEOF'
import json, sys
from collections import defaultdict

data                = json.load(open(sys.argv[1]))
out_path            = sys.argv[2]
timestamp           = sys.argv[3]
total               = int(sys.argv[4])
snyk_ran            = sys.argv[5] == "1"
pip_audit_skipped   = sys.argv[6] == "1"
run_pip_audit       = sys.argv[7] == "1"
run_trivy           = sys.argv[8] == "1"
lane                = sys.argv[9]

findings = data.get("findings", [])
s = data.get("summary", {})

iac_by_sev = defaultdict(int)
for f in findings:
    if f.get("category") == "IaC":
        iac_by_sev[f.get("severity", "UNKNOWN")] += 1

sca_findings = [f for f in findings if f.get("category") == "SCA"]
iac_findings = [f for f in findings if f.get("category") == "IaC"]

lines = []
lines.append("# Orbit -- Supply Chain Baseline")
lines.append("")
lines.append(f"**Generated:** {timestamp}")
lines.append(f"**Lane:** {lane}")
if lane == "trivy":
    lines.append(f"**Baseline total (Trivy only -- iac + fs):** {total}")
elif lane == "pip-audit":
    if pip_audit_skipped:
        lines.append(f"**Baseline total (pip-audit lane -- skipped in this env):** {total}")
    else:
        lines.append(f"**Baseline total (pip-audit only):** {total}")
else:
    if pip_audit_skipped:
        lines.append(f"**Baseline total (Trivy only; pip-audit: skipped):** {total}")
        lines.append(f"**pip_audit:** skipped (env) -- broken ensurepip/nested-venv on this host; trivy carried the lane")
    else:
        lines.append(f"**Baseline total (pip-audit + Trivy):** {total}")
if snyk_ran:
    snyk_extra = s.get("snyk_dep_vulns", 0) + s.get("snyk_iac_issues", 0)
    lines.append(f"**Snyk (premium):** {snyk_extra} additional finding(s)")
lines.append("")
lines.append("This is the consumer's committed supply-chain baseline. Each finding is a")
lines.append("known vulnerability or IaC misconfiguration tracked for remediation. The")
lines.append("committed baseline file locks this number for CI gating.")
lines.append("")
lines.append("## Tool Summary")
lines.append("")
lines.append("| Tool | Type | Findings |")
lines.append("|------|------|----------|")
if not run_pip_audit:
    lines.append("| pip-audit | SCA -- Python dependencies | *not in lane* |")
elif pip_audit_skipped:
    lines.append("| pip-audit | SCA -- Python dependencies | *skipped (env -- broken ensurepip)* |")
else:
    lines.append(f"| pip-audit | SCA -- Python dependencies | {s.get('pip_audit_vulns', 0)} vulnerabilities |")
if not run_trivy:
    lines.append("| trivy config | IaC -- misconfigurations | *not in lane* |")
    lines.append("| trivy fs | SCA -- dependency scan | *not in lane* |")
else:
    lines.append(f"| trivy config | IaC -- misconfigurations | {s.get('trivy_iac_misconfigs', 0)} findings |")
    lines.append(f"| trivy fs | SCA -- dependency scan | {s.get('trivy_fs_vulns', 0)} vulnerabilities |")
if snyk_ran:
    lines.append(f"| snyk test | SCA -- Python deps (premium) | {s.get('snyk_dep_vulns', 0)} vulnerabilities |")
    lines.append(f"| snyk iac | IaC -- Terraform (premium) | {s.get('snyk_iac_issues', 0)} findings |")
else:
    lines.append("| snyk | SCA+IaC (premium) | *Token not set -- see Snyk upgrade note* |")
lines.append("")

if iac_findings:
    lines.append("## IaC Misconfigurations by Severity (Trivy config)")
    lines.append("")
    lines.append("| Severity | Count |")
    lines.append("|----------|-------|")
    for sev in ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]:
        count = iac_by_sev.get(sev, 0)
        if count:
            lines.append(f"| {sev} | {count} |")
    lines.append("")

if sca_findings:
    lines.append("## SCA Vulnerabilities (pip-audit + trivy fs)")
    lines.append("")
    lines.append("| Tool | Package | Version | ID | Fix | Aliases |")
    lines.append("|------|---------|---------|-----|-----|---------|")
    for f in sorted(sca_findings, key=lambda x: x.get("package", "")):
        tool = f.get("tool", "?")
        pkg = f.get("package", "?")
        ver = f.get("version", f.get("installed_version", "?"))
        vid = f.get("id", "?")
        fix = ", ".join(f.get("fix_versions", [])) or f.get("fixed_version", "") or "--"
        aliases = ", ".join(f.get("aliases", []))[:60] or "--"
        lines.append(f"| {tool} | `{pkg}` | {ver} | `{vid}` | {fix} | {aliases} |")
    lines.append("")

if not snyk_ran:
    lines.append("## Snyk Upgrade Note")
    lines.append("")
    lines.append("Snyk premium provides:")
    lines.append("- DeepCode AI autofix patches applied automatically")
    lines.append("- Snyk MCP integration for agent-driven remediation")
    lines.append("- Reachability analysis (are these vulns actually exploitable?)")
    lines.append("")
    lines.append("**To activate:** obtain a Snyk token and set `SNYK_TOKEN` as a GitHub Actions")
    lines.append("secret in the CONSUMER repo. supply-run.sh will automatically pick it up.")
    lines.append("")

lines.append("---")
lines.append("*Generated by `scripts/supply-run.sh` -- Orbit (ynetplus/orbit)*")

with open(out_path, "w") as fh:
    fh.write("\n".join(lines) + "\n")

print(f"Summary written to {out_path}")
PYEOF

# -- 8. Cleanup temp files -----------------------------------------------------
rm -f "$TMP_PIP_AUDIT" "$TMP_TRIVY_IAC" "$TMP_TRIVY_FS" "$TMP_SNYK_DEPS" "$TMP_SNYK_IAC"

echo ""
echo "Outputs:"
echo "  JSON findings:  $FINDINGS_JSON"
echo "  MD summary:     $SUMMARY_MD"
echo "  Baseline count: $BASELINE_COUNT_OUT ($BASE_TOTAL)"
if [ "$RUN_PIP_AUDIT" = "1" ] && [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
  echo "  pip-audit:      SKIPPED (env) -- trivy carried the lane"
fi
echo ""

# -- 9. CI mode: block on NEW violations only ----------------------------------
if [ "$CI_MODE" = "1" ]; then
  echo "=============================================================="
  echo "CI MODE: comparing against committed baseline"
  echo "Baseline file: $BASELINE_FILE"
  echo "=============================================================="

  if [ ! -f "$BASELINE_FILE" ]; then
    echo "WARNING: No baseline file found at $BASELINE_FILE"
    echo "Committing current count as baseline. Run:"
    echo "  echo $BASE_TOTAL > $BASELINE_FILE"
    echo "  git add $BASELINE_FILE && git commit -m 'chore: supply baseline'"
    echo "WARN_NO_BASELINE: $BASE_TOTAL findings (no baseline to compare against)"
    exit 0
  fi

  COMMITTED_BASELINE=$(cat "$BASELINE_FILE" | tr -d '[:space:]')
  echo "Committed baseline: $COMMITTED_BASELINE findings"
  echo "Current scan:       $BASE_TOTAL findings"
  echo ""

  if [ "$BASE_TOTAL" -gt "$COMMITTED_BASELINE" ]; then
    NEW_COUNT=$((BASE_TOTAL - COMMITTED_BASELINE))
    echo "=============================================================="
    echo "BLOCKED: $NEW_COUNT NEW supply-chain finding(s) introduced!"
    echo "=============================================================="
    echo ""
    echo "The supply scan found $BASE_TOTAL findings in this PR."
    echo "The committed baseline allows $COMMITTED_BASELINE."
    echo ""
    echo "You have introduced $NEW_COUNT new supply-chain finding(s)."
    echo "Fix them before merging."
    echo ""
    echo "Run locally:  ./scripts/supply-run.sh --lane $LANE --baseline-file $BASELINE_FILE"
    echo "Findings:     $SUMMARY_MD"
    echo ""
    head -50 "$SUMMARY_MD"
    exit 1
  elif [ "$BASE_TOTAL" -lt "$COMMITTED_BASELINE" ]; then
    FIXED=$((COMMITTED_BASELINE - BASE_TOTAL))
    echo "GREAT: $FIXED supply finding(s) were fixed in this PR!"
    echo "Update the baseline: echo $BASE_TOTAL > $BASELINE_FILE"
    echo "WARN_BASELINE_STALE: Current=$BASE_TOTAL Baseline=$COMMITTED_BASELINE (update recommended)"
  else
    echo "PASS: No new supply-chain findings introduced ($BASE_TOTAL = baseline $COMMITTED_BASELINE)."
  fi
  echo ""
fi

echo "=============================================================="
echo "Supply chain scan complete -- $BASE_TOTAL finding(s) (lane: $LANE)"
if [ "$RUN_PIP_AUDIT" = "1" ] && [ "$PIP_AUDIT_SKIPPED" = "1" ]; then
  echo "(pip-audit skipped -- trivy carried the lane)"
fi
echo "=============================================================="
