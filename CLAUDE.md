# Orbit — Project Documentation Index

> **Orbit** = YNET Plus Inc.'s central framework repo: versioned, reusable GitHub Actions
> workflows for the CI/CD gates every product repo needs. **No application code, no runtime,
> no deploy** — see full README.md for the consumer contract (SHA-pin discipline, Tier 1/2
> workflow split, the fail-closed aggregator pattern).
> Company context: `~/.claude/CLAUDE.md`. Work registry: KEYSTONE.
> First read: `~/Work/keystone/OMBRELLA.md` (router) — Orbit work lives in `kpm/products/ynetplus/cr/`
> (Orbit ships under PRJ-A085/PRJ-A079; it has no product-specific `kpm/products/orbit/` tree yet).

---

## Agent Context

Agents read this section before starting any task. Global agents (`~/.claude/commands/`) use this
to adapt behavior to this repo. **Never assume YNET+ (or any consumer product's) defaults.**

- **Product:** Orbit (YNET Plus Inc.) — standalone, own repo. **A framework repo, not a product**:
  it has no users, no UI, no domain data, and nothing here is ever deployed.
- **Type:** Reusable CI/CD workflow library, consumed by `ynetplus`, `onest`, and `keystone` (and
  future consumers) via `uses: ynetplus/orbit/.github/workflows/<file>.yml@<40-char-sha>`.
- **Repo (this product):** `~/Work/orbit` — **standalone**, `github.com/ynetplus/orbit`. Primary
  branch: `main`.
- **Design system:** N/A — no application, no UI, nothing user-facing.
- **Tech stack:** GitHub Actions YAML (`.github/workflows/`) + a handful of Python/shell engine
  scripts under `scripts/` that the Tier-2 reusable workflows shell out to. No backend, no
  frontend, no database.
- **Test command:** no application test suite exists (there is no app to test). What's actually
  here and actually runs:
  - Locally: `actionlint -shellcheck= .github/workflows/*.yml` (structural workflow validation)
    and `yamllint -c .yamllint.yml .github/workflows/` (generic YAML style/syntax) — both pinned
    versions are in `.github/workflows/orbit-ci.yml`.
  - `self-test/` holds only **fixtures** (`self-test/fixtures/`) — baseline files, injected-secret
    text, Alembic conflict/ok migration trees, a Dockerfile — consumed by the actual self-test
    *workflows*, `.github/workflows/self-test.yml` (GREEN path) and
    `.github/workflows/self-test-red-path.yml` (RED path, `workflow_dispatch` only). These run on
    GitHub Actions against the fixtures and prove each reusable workflow goes GREEN on a clean
    fixture and RED on the matching bad one — see README.md § "Testing a change to this repo" for
    how to dispatch and read the red path locally via `gh run view --json conclusion,jobs`.
  - `orbit-ci.yml` (`actionlint` + `yamllint` + the reusable-workflow-shape check) is the required
    PR gate on `main`.
- **Pre-forge check:** none.
- **Local QA gate:** none — no running system to health-check. E2E verification on this repo means
  running the local lint commands above and, where a change touches step logic (not just YAML
  shape), extracting and executing that logic directly against constructed fixtures.
- **Migration tool:** N/A — no database, no migrations.
- **Deploy method:** **none.** This repo is never deployed, installed, or run as a service. Its
  only "shipping" mechanism is a consumer bumping its pinned commit SHA in a `uses:` line after an
  Orbit PR merges to `main` — see README.md §§1 and "Adopting Orbit in a new product".
- **CR location (KEYSTONE):** Orbit changes are filed under whichever PRJ is driving them
  (currently `kpm/products/ynetplus/cr/`, e.g. CR-A085-50) — there is no separate
  `kpm/products/orbit/` CR tree as of this writing.
- **Worktree / branches:** standalone product — cut a worktree under `~/Work/orbit` for isolation,
  or work directly on a feature branch (`feature/CR-XXX-...`) in `~/Work/orbit` for a serial single
  CR. Do not push `main` directly; PRs merge to `main` after `orbit-ci.yml` is green.
- **Forge report / CR docs:** still committed to **keystone** (`kpm/products/ynetplus/cr/`,
  `kpm/products/ynetplus/cr/reports/`), separate from the Orbit code commits, per the standard
  standalone-product chain rules.

> Global agents: `~/.claude/commands/` — DO NOT duplicate agent files in a local `.claude/commands/`
> here.

---

## What this repo is not

No product code, no product data, no secrets, no deploy pipeline of its own. See README.md §
"What does NOT belong here" for the exhaustive list. If a task looks like it wants Orbit to grow
an application, a database, or a running service, that is out of scope for this repo by design —
raise it as a new product instead.
