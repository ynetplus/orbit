# Gate Evidence

One row per gate: what it catches, and the evidence it was worth extracting
into a shared framework. Per the gate-rationalization-evidence-standard DEC
(Drew-ratified 2026-07-03, PRJ-A079 Phase-3): a gate earns a place in Orbit
only if it has a real catch or a structural argument, not "seemed like a
good idea." All catch-rate references below are to the `ynetplus` incidents
that motivated the original gate (pre-extraction); Orbit's job is to make
that same protection available to every other product without re-deriving
it.

| Gate | What it catches | Evidence |
|---|---|---|
| `secret-detection.yml` | Committed secrets (API keys, tokens, private keys, high-entropy strings) in PR diffs | `ynetplus` CR-458 origin; entropy/keyword detection has no free-tier native equivalent (GHAS Secret Protection is a paid upgrade, RN-019 Decision 2: deferred). Live-proven both directions in this CR's `self-test.yml` (clean-fixture PASS / injected-AWS-key-fixture FAIL). `exclude_globs` (CR-A079-14 Part O / F4, Third Eye LED-041 F4) additionally live-proven both directions: an excluded path's fake secret is skipped (`secret-detection-exclude-globs-pass`) and a non-excluded fake secret still blocks (`secret-detection-exclude-globs-still-blocks-fail`). |
| `nightly-secrets-full-scan.yml` | Secrets that slipped past the incremental PR scan (e.g. baseline edited without review, or a file the PR-time diff doesn't touch) | `ynetplus` CR-CI-021 — full-repo parity companion to the incremental PR gate; catches drift the incremental scan is structurally blind to. |
| `aws-credentials-ban.yml` | Static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` anywhere in `.github/workflows/`, i.e. any workflow not yet migrated to OIDC | `ynetplus` CR-242c — origin of the company's OIDC-only CI/CD policy; this gate is the enforcement backstop for that policy. |
| `sast-bandit.yml` | Python SQL injection, shell injection, hardcoded passwords, insecure crypto (HIGH severity + HIGH confidence only) | `ynetplus` CR-458 — SAST coverage with no reliance on a paid code-scanning product; Bandit is the standard Python SAST tool. |
| `alembic-single-head.yml` | Multiple Alembic head revisions (a migration branch conflict that silently strands one branch's migrations at deploy time) | `ynetplus` migration-standard gate, live since early CI. Live-proven both directions in this CR's `self-test.yml` (1-head fixture PASS / 2-head fixture FAIL). |
| `migration-lock-risk.yml` | DDL patterns that acquire long-held PostgreSQL locks on production tables (`CREATE INDEX` without `CONCURRENTLY`, `ALTER COLUMN ... NOT NULL`, type changes, unvalidated `ADD CONSTRAINT`/FK, `DROP TABLE`) | `ynetplus` CR-A078-14, direct response to the GoCardless 15-second-outage post-mortem cited in RN-019 §3 — "our empty-build + online-validation gates prove correctness but are blind to lock contention." WARN-only; never hard-blocks. |
| `ci-health-watchdog.yml` | A scheduled gate that's been red >48h without anyone noticing, AND (Dead-Man's-Switch) a scheduled gate that stopped firing entirely (cron silently disabled after ~60 days of repo inactivity, or the `schedule:` trigger got deleted) | `ynetplus` CR-A078-6 / CR-A078-16 — RN-019 §3 "Dead-Man's-Switch... stronger than a watchdog that only catches red runs." |
| `branch-protection-drift-check.yml` | Required branch-protection contexts silently drifting from the locked contract (e.g. a context gets renamed/removed from GitHub's UI and nothing else notices) | `ynetplus` CR-A079-6, filed directly in response to [[BF-167]] — `Security Gate` fell out of `main`/`stage`'s required contexts and was undetected until a manual Third-Eye audit. Detection only; never mutates protection. |
| `pipeline-slo.yml` | Build-duration p95 creep, success-rate degradation, and queue-wait p95 creep on the watched pipeline workflow | `ynetplus` CR-A078-18 — RN-019 §4 "CI/CD as an SLO'd system... not a dashboard wall." |
| `repo-clean-check.yml` | Build/test steps that silently mutate or generate tracked files (accidental commits of build artifacts, generated code drifting from source) | `ynetplus` `repo-clean-post-build` job, standing HARD BLOCK since early CI; zero-tolerance policy on an unclean post-build tree. |
| `enforce-branch-flow.yml` | A PR into the protected target branch from anywhere other than the one allowed promotion branch (prevents skip-stage direct-to-main merges) | `ynetplus` `gate-stage-to-main.yml`, LOCKED deployment-pipeline-contract v1.0 — the single-lane promotion invariant every release depends on. |
| `sast-semgrep.yml` (Tier 2) | Whatever the CONSUMER's own Semgrep ruleset encodes (in `ynetplus`: tenant-slug hardcoding, default-tenant symbol leaks, unsanitized public-route exceptions) | `ynetplus` CR-A055-1 — the engine is generic; the catch depends entirely on the ruleset each product brings. Engine correctness (finds/counts findings, diffs against baseline, emits SARIF) is the part Orbit owns and is covered by this CR's extraction review. |
| `supply-audit.yml` (Tier 2) | Whatever Trivy (IaC misconfig + FS dependency scan) and pip-audit (Python SCA) find against the CONSUMER's own infra/backend trees | `ynetplus` CR-A078-3 — the engine (scan, diff-vs-baseline, aggregate, optional Snyk) is generic; findings depend on each product's actual infra/dependency tree. |

## Gates NOT extracted (explicitly out of scope, per CR-A079-8)

`ynetplus`-specific gates with no ≥2-product justification stay in
`ynetplus`: empty-build gate, backend-test shards, E2E Playwright suite,
prod-path-sim, money-invariant smoke gate, SQL-residue router/service
inventory gate. See CR-A079-13 (ynetplus consumes Orbit) for the final split
once `ynetplus` itself migrates its Tier-1/2 gates onto these reusable
workflows.

## Live QA proof (this CR)

Per CR-A079-8's QA Scenarios:

1. **secret-detection green/red** — proven live via `secret-detection-pass`
   (`self-test.yml`) and `secret-detection-fail` (`self-test-red-path.yml`),
   both against the same committed AWS-example-key fixture
   (`self-test/fixtures/secrets/`), one with the finding pre-baselined
   (PASS) and one without (FAIL). Split across two workflow files because a
   `uses:`-only job cannot carry `continue-on-error:` — see
   `self-test-red-path.yml`'s header comment.
2. **alembic-single-head green/red** — proven live via
   `alembic-single-head-pass` (`self-test.yml`, 1-head fixture) and
   `alembic-single-head-fail` (`self-test-red-path.yml`, 2-head fixture),
   `self-test/fixtures/alembic-{ok,conflict}/`.
3. **actionlint catches malformed YAML** — proven live via a one-off
   scratch PR against this repo with a deliberately malformed workflow file
   under `.github/workflows/`, observed to fail `orbit-ci.yml`'s `actionlint`
   job, then closed without merging. See the CR-A079-8 forge report for the
   run link.
4. **README-only adoption** — CR-A079-11 (Cairo, no pre-existing `.github/`
   at all) is the live test that a fresh agent can wire a new product from
   this README alone.
5. **`exclude_globs` (CR-A079-14 Part O / F4)** — proven live via
   `secret-detection-exclude-globs-pass` (`self-test.yml`) and
   `secret-detection-exclude-globs-still-blocks-fail`
   (`self-test-red-path.yml`), both against
   `self-test/fixtures/secrets/exclude-globs/injected-should-be-excluded.txt`
   (excluded) and the pre-existing `self-test/fixtures/secrets/injected.txt`
   (not excluded, sibling path). One `exclude_globs` pattern
   (`self-test/fixtures/secrets/exclude-globs/*`) held constant across both
   jobs; only the baseline differs (see `self-test.yml`'s header comment for
   why `pass.secrets.baseline` — not `known.secrets.baseline` — is what
   actually proves exclusion, not pre-baselining, keeps the PASS job green).
