# Orbit 🛰️

Orbit is YNET Plus Inc.'s central framework repo: versioned, reusable GitHub
Actions workflows for the CI/CD gates every product repo needs and no two
products should hand-build separately. One fix here propagates to every
consumer the next time it bumps its pinned SHA.

**Status:** PRJ-A079 Phase 3 (CR-A079-8). Extracted from `ynetplus`'s proven
gates (the reference implementation, PRJ-A078). First consumers: Onest
(CR-A079-10), Cairo (CR-A079-11), Control Tower (CR-A079-12), then `ynetplus`
itself (CR-A079-13).

Design decisions (framework shape, SHA-pin discipline, Tier 1/2 split) come
from [RN-019 — Golden Pipeline Framework Decision Synthesis](https://github.com/ynetplus)
(keystone `shared/research/RN-019-golden-pipeline-decision-synthesis.md`),
Drew-signed-off 2026-06-27.

---

## Consumer prerequisites

Before any consumer repo's `uses: ynetplus/orbit/...@<sha>` calls will work,
this repo's **Actions → General → Access** setting must be **"Accessible from
repositories in the `ynetplus` organization"** (`access_level=organization`),
not the GitHub default of "Not accessible" / repo-only:

```bash
gh api -X PUT repos/ynetplus/orbit/actions/permissions/access \
  -f access_level=organization
```

**Symptom when this is wrong:** every consumer job that calls an Orbit
reusable workflow fails immediately with an opaque, unhelpful error —
GitHub reports it as a generic **"workflow file issue"** / "workflow was not
found" on the caller side, with nothing in the log pointing at an access
setting. It looks identical to a typo'd `uses:` path or a bad SHA pin, so
don't assume the caller YAML is wrong before checking this setting.

This is an org/repo-level setting on `ynetplus/orbit` itself (not something
each consumer configures) — **already fixed live** as of this writing.
Documented here so it isn't silently mis-set again and so the failure mode is
recognizable if it ever regresses.

---

## The contract: how to consume a workflow from this repo

### 1. Pin the full commit SHA — never a branch or tag

```yaml
jobs:
  secret-scan:
    uses: ynetplus/orbit/.github/workflows/secret-detection.yml@<40-char-sha>
    with:
      baseline_path: .secrets.baseline
      base_ref: stage
```

**Why SHA, not `@main` or `@v1`:** a mutable ref can be silently re-pointed
(the `tj-actions/changed-files` CVE-2025-30066 incident — 23,000 repos
compromised via a retroactively re-pointed tag — is the reference case cited
in RN-019). A 40-character commit SHA cannot be re-pointed; it names one
immutable tree forever.

**To find the SHA to pin:** use the SHA of the commit you want on Orbit's
`main` branch — `git -C orbit log --oneline -1` after any change you've
reviewed, or the merge commit SHA of the PR that shipped the change you want.
There is no moving major tag in this repo (unlike some marketplace actions);
every consumer update is a deliberate SHA bump, ideally proposed by
Dependabot once Orbit's release cadence stabilizes (see "Versioning" below).

### 2. Every reusable workflow takes `inputs:` — read the table below

Every workflow in `.github/workflows/` declares `on: workflow_call:` with a
documented `inputs:` block (defaults preserve `ynetplus`'s exact original
behavior — no input required to reproduce the extracted gate as-is). Read the
workflow file's own header comment for the extraction provenance and any
Tier-2 engine-script notes; the table below is the quick-reference index.

### 3. The fail-closed aggregator pattern (copy, don't reuse — inherently per-repo)

Consumers that call multiple Orbit workflows from one PR-triggered workflow
file need ONE stable required-status-check context (not N path-conditional
ones — see `ynetplus` CR-A079-1, the origin of this pattern: path-conditional
required contexts report `skipped` on some PRs, and GitHub treats a
required-but-skipped check as unsatisfied, forcing break-glass admin merges).
The fix is an aggregator job that runs `if: always()` and passes when every
listed job is `success` OR `skipped`, failing only on `failure`/`cancelled`:

```yaml
jobs:
  secret-scan:
    uses: ynetplus/orbit/.github/workflows/secret-detection.yml@<sha>
    with: { baseline_path: .secrets.baseline }

  aws-ban:
    uses: ynetplus/orbit/.github/workflows/aws-credentials-ban.yml@<sha>

  sast:
    uses: ynetplus/orbit/.github/workflows/sast-bandit.yml@<sha>
    with: { scan_path: backend/ }

  ci-gate:
    name: CI Gate                      # <- THIS becomes the required branch-protection context
    runs-on: ubuntu-latest
    if: always()
    needs: [secret-scan, aws-ban, sast]
    steps:
      - name: Fail if any required job FAILED (skip/success are OK)
        run: |
          RESULTS='${{ toJSON(needs) }}'
          if echo "$RESULTS" | grep -q '"result": *"failure"' || echo "$RESULTS" | grep -q '"result": *"cancelled"'; then
            echo "❌ A required job failed/cancelled — blocking."
            exit 1
          fi
          echo "✅ CI Gate PASS."
```

This aggregator is deliberately **not** an Orbit reusable workflow — its
`needs:` list is inherently per-repo (it names YOUR job IDs). Copy the
pattern above into your consumer workflow; do not try to import it.

### 4. Branch protection

Point your repo's required-status-check contexts at your aggregator job
names (e.g. `CI Gate`, `Security Gate`), not at the individual Orbit job
names inside each called workflow — GitHub exposes a called reusable
workflow's job as `<caller-job-id> / <called-job-name>` in the checks list,
which is a mouthful and moves if you rename either side. The aggregator
pattern above gives you one stable name to point branch protection at.

### 5. Secrets

Reusable workflows that need a secret declare it under `secrets:` in their
`workflow_call:` block (see `branch-protection-drift-check.yml` and
`supply-audit.yml`). Pass it explicitly from the caller:

```yaml
jobs:
  drift-check:
    uses: ynetplus/orbit/.github/workflows/branch-protection-drift-check.yml@<sha>
    with: { expected_contexts: '{"main":"CI Gate,Security Gate"}' }
    secrets:
      branch_protection_readonly_token: ${{ secrets.BRANCH_PROTECTION_READONLY_TOKEN }}
```

Or use `secrets: inherit` if your org policy allows it. Orbit workflows never
hardcode a secret name that isn't declared in their own `secrets:` block —
no product data or credentials live in this repo (see "What does NOT belong
here" below).

---

## Reusable workflows (Tier 1 — fully agnostic)

| Workflow | Purpose | Key inputs |
|---|---|---|
| [`secret-detection.yml`](.github/workflows/secret-detection.yml) | HARD BLOCK — detect-secrets incremental PR scan vs committed baseline | `baseline_path`, `base_ref`, `exclude_globs` |
| [`nightly-secrets-full-scan.yml`](.github/workflows/nightly-secrets-full-scan.yml) | Scheduled full-repo detect-secrets parity scan; opens a triage issue on drift | `baseline_path`, `label` |
| [`aws-credentials-ban.yml`](.github/workflows/aws-credentials-ban.yml) | HARD BLOCK — forbids static AWS keys anywhere in `.github/workflows/` | `exclude_files` |
| [`sast-bandit.yml`](.github/workflows/sast-bandit.yml) | HARD BLOCK on Bandit HIGH/HIGH findings | `scan_path`, `bandit_config` |
| [`alembic-single-head.yml`](.github/workflows/alembic-single-head.yml) | HARD BLOCK — `alembic heads` must resolve to exactly 1 head | `alembic_dir`, `requirements_file`, `python_version` |
| [`migration-lock-risk.yml`](.github/workflows/migration-lock-risk.yml) | WARN — flags DDL patterns in new migrations that acquire long-held Postgres locks | `migrations_glob`, `base_ref` |
| [`ci-health-watchdog.yml`](.github/workflows/ci-health-watchdog.yml) | Scheduled Dead-Man's-Switch — flags a scheduled gate that's red >48h OR stopped firing entirely | `watched` (JSON), `branch`, `threshold_hours` |
| [`branch-protection-drift-check.yml`](.github/workflows/branch-protection-drift-check.yml) | Scheduled read-only assertion that live required-status-checks match your locked contract | `expected_contexts` (JSON), secret `branch_protection_readonly_token` |
| [`pipeline-slo.yml`](.github/workflows/pipeline-slo.yml) | Scheduled SLO watchdog — build-duration p95 / success-rate / queue-wait p95 | `watched_workflow`, threshold inputs |
| [`repo-clean-check.yml`](.github/workflows/repo-clean-check.yml) | HARD BLOCK — no modified/untracked files survive your build/test steps | `paths` |
| [`enforce-branch-flow.yml`](.github/workflows/enforce-branch-flow.yml) | HARD BLOCK — only `allowed_source` may PR into `protected_target` | `allowed_source`, `protected_target` |

## Reusable workflows (Tier 2 — agnostic engine, your ruleset/baseline stays in your repo)

| Workflow | Purpose | Key inputs |
|---|---|---|
| [`sast-semgrep.yml`](.github/workflows/sast-semgrep.yml) | Runs YOUR Semgrep ruleset; WARN-on-existing / HARD-BLOCK-on-NEW vs your committed baseline count | `rules_dir`, `scan_path`, `baseline_file`, `semgrep_version` |
| [`supply-audit.yml`](.github/workflows/supply-audit.yml) | Trivy (IaC + FS) + pip-audit supply-chain scan, `lane` selectable, vs your committed baseline count | `lane`, `baseline_file`, `backend_path`, `infra_path`, `requirements_glob`, secret `snyk_token` |

Tier 2's *engine* (this repo's `scripts/supply-run.sh` / `scripts/semgrep-run.sh`)
is product-agnostic; your ruleset files and baseline counts are product data
and stay in YOUR repo, passed in as paths. The reusable workflow self-checks-out
this repo at the exact SHA it was invoked at, via the `job` context's
`workflow_repository` / `workflow_sha` fields (GitHub docs: "Contexts" ->
"job context" — these identify the CALLED reusable workflow's own
`owner/repo` + exact pinned commit SHA; the top-level `github.workflow_ref`
always identifies the CALLER's workflow instead and must never be used for
this) to fetch the matching engine script version — no separate ref to keep
in sync.

---

## What does NOT belong here

- **No secrets.** No product credentials, tokens, or API keys — ever.
- **No product data.** Semgrep rulesets, supply-chain baselines, `.secrets.baseline`
  files stay in the consumer repo and are passed in as input paths.
- **No product-specific gates.** Anything only `ynetplus` needs (e.g. its
  empty-build gate, backend-test shards, e2e suite, prod-path-sim,
  money-invariant smoke, SQL-residue inventory) stays in `ynetplus`. This
  repo only holds gates that are genuinely useful to ≥ 2 products.

## Versioning

No moving major tag yet (RN-019 Decision — `main` + full-SHA pin only, at
this repo's current size). If Orbit outgrows manual SHA bumps, the next step
is a Dependabot-managed `uses:` update PR per consumer, not a floating tag —
see RN-019 §3 for why floating tags are explicitly rejected for this repo.

## Testing a change to this repo

1. `docs/GATE-EVIDENCE.md` — update the row for any gate whose behavior
   you're changing.
2. Every reusable workflow's own inline comments explain what it was
   extracted from and why — keep the extraction diff-reviewable (RN-019
   invariant: "behaviorally identical to source, not a rewrite").
3. Push to a feature branch and open a PR into `main` — Orbit's own CI
   (`orbit-ci.yml`) runs `actionlint` + `yamllint` + a reusable-workflow
   shape check against every workflow file.
4. `self-test.yml` (GREEN path — schedule/PR/push) and
   `self-test-red-path.yml` (RED path — `workflow_dispatch` only, because a
   `uses:`-only job cannot carry `continue-on-error:`, so a job that is
   SUPPOSED to fail can't safely share a run with jobs that must stay green)
   together call a subset of the reusable workflows against committed
   fixtures under `self-test/fixtures/` and prove each one goes GREEN on a
   clean fixture and RED on the matching bad fixture — see each workflow's
   header comment for the fixture design and how to dispatch + verify the
   red path via `gh run view --json conclusion,jobs`.
5. Merge only after `main`'s required checks (`Orbit CI`, and `Orbit
   Self-Test (Live QA Proof — GREEN path)` for changes it covers) are green.

## Adopting Orbit in a new product

1. Read this README end-to-end (you just did).
2. Pick the Tier 1 gates your product needs from the table above; for Tier 2,
   also bring your own ruleset/baseline files.
3. Write your consumer `.github/workflows/*.yml` files, each `uses:`-ing the
   Orbit workflow you want at today's `main` SHA (`git ls-remote
   https://github.com/ynetplus/orbit main` or check the latest commit in the
   GitHub UI), with the `with:` inputs your repo needs.
4. Wire the fail-closed aggregator pattern (§3 above) if you're calling more
   than one Orbit workflow from a single PR gate.
5. Point branch protection at your aggregator job name(s).
6. See `docs/GATE-EVIDENCE.md` for what each gate actually catches, so you
   only adopt the ones relevant to your product's risk profile.

(CR-A079-11 — Cairo's from-zero adoption, no pre-existing `.github/` at all —
is the live test of whether this README alone is sufficient for a fresh
agent to wire a new product. If it wasn't, that CR's forge report should
propose a fix to this file.)

## Adoption notes (things that bite on first adoption, not covered above)

**(a) `workflow_dispatch` only works once the workflow file is on the default
branch.** This is a general GitHub Actions platform constraint, not an Orbit
quirk, but it hits every consumer that tries to pre-merge-test a brand-new
`workflow_dispatch`-triggered caller (e.g. `nightly-secrets-full-scan.yml`,
`ci-health-watchdog.yml`, `branch-protection-drift-check.yml`,
`pipeline-slo.yml`): `gh workflow run <file> --ref <feature-branch>` fails
with `HTTP 404: workflow ... not found on the default branch`, regardless of
`--ref`, until that workflow file exists on `main` (or whatever the repo's
default branch is). Two honest ways to QA a new scheduled caller before it
merges:
- Add a temporary `push: branches: [<your-feature-branch>]` trigger to the
  file, push, capture the run, then **remove the temp trigger** before the
  final push — this exercises the identical job body (the reusable-workflow
  call) that `workflow_dispatch` would, so it's a faithful proof, not a
  workaround of the thing being tested.
- Or accept that first-time `workflow_dispatch` QA happens **post-merge**,
  once the file has landed on the default branch.
(Onest CR-A079-10, Cairo CR-A079-11, and Control Tower CR-A079-12 all hit and
independently worked around this the first way.)

**(b) `branch-protection-drift-check.yml` needs a token your repo doesn't
have by default.** It calls `GET /repos/{owner}/{repo}/branches/{branch}/protection`
with `Administration: Read-only`, a permission the default `GITHUB_TOKEN` can
never be granted (GitHub Actions tokens cap out below repo-Administration).
Provision `secrets.BRANCH_PROTECTION_READONLY_TOKEN`: a **fine-grained
personal access token**, scoped to your repo only, with **Administration:
Read-only** and nothing else — minted interactively via the GitHub web UI
(Settings → Developer settings → Fine-grained tokens), there is no API/CLI
path to create it non-interactively. Until it's provisioned, the workflow
fails with a documented, distinct error — `"🔑 AUTH/PERMISSION ERROR (not
branch-protection drift)"` / `{"message":"Resource not accessible by
integration","status":"403"}` — which is the correctly-wired failure mode,
not real drift. Once the secret is set, the same run goes green with no code
change.
