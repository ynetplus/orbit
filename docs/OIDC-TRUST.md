# OIDC Trust Scoping — Canonical Template

**Provenance:** the 2026-08-08 Onest-SRE infrastructure audit
(`kkm/products/onest/audits/2026-08-08-mahmoud-infra-vs-orbit-reference-audit.md`,
§1.3 / §4.8) found the same account's two OIDC deploy roles trusted at two
different scopes with no documented reason — one tight (`sub` pinned to an
exact repo+branch), one broad (`StringLike` wildcard on any ref in the repo)
— and flagged it as worth a conscious decision rather than an
undocumented accident. This doc is that decision, written down once so every
Orbit-consuming product's deploy roles get scoped the same deliberate way
instead of each re-deriving it (or drifting).

This is a **template + policy**, not a script — creating/modifying an IAM
role or its trust policy is an infra change, out of Orbit's scope (Orbit
ships CI/CD workflow primitives, never touches IAM). Apply this by hand or
via your product's own Terraform, the same way each product already
provisions its OIDC provider and deploy roles.

---

## The rule

**One IAM role per pipeline purpose, trusted for exactly the `sub` claim
that pipeline actually runs as — never broader.** A role's trust policy is
the real access-control boundary; a workflow-level branch `if:` check is not
one, because it can be edited or bypassed in ways the trust policy cannot.

## Canonical trust-policy template

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:ref:refs/heads/<BRANCH>"
        }
      }
    }
  ]
}
```

Swap the `sub` condition's value per pipeline purpose:

| Pipeline purpose | `sub` condition value | Notes |
|---|---|---|
| Deploy to production on merge to `main` | `repo:ORG/REPO:ref:refs/heads/main` | Exact branch — this is the tight, correct pattern. |
| Deploy to staging on merge to `stage` | `repo:ORG/REPO:ref:refs/heads/stage` | Separate role from production; never share one role across environments. |
| Deploy gated by a GitHub Environment (required reviewer) | `repo:ORG/REPO:environment:production` | Prefer this over a branch `sub` when the repo has GitHub Environments with protection rules available (Free-plan orgs cannot use Environment protection rules — see the audit's §1.1; branch-`ref` scoping is then the best available substitute, not equivalent). |
| A specific reusable/called workflow only | `repo:ORG/REPO:job_workflow_ref:ORG/REPO/.github/workflows/FILE.yml@refs/heads/main` | Tightest option — scopes to one workflow file, not just one branch. Use when a repo has multiple workflows on `main` and only one of them should ever hold this role. |

`aud` (`sts.amazonaws.com`) stays `StringEquals` always — GitHub's own OIDC
guidance. Use `StringLike` only where a genuine wildcard is required (rare —
see the anti-pattern below for why it usually isn't), and if you do, scope
the wildcard as narrowly as the real use case allows (e.g. `ref:refs/tags/v*`
for a tag-triggered release role, never a bare `*`).

## One role per pipeline purpose

Do not reuse one deploy role across production and staging, or across app
deploy and infra apply. Each purpose gets its own role with its own trust
condition and its own (least-privilege) permissions policy — this bounds the
blast radius of a compromised or misconfigured workflow to exactly the one
thing that role can do, and it is what let the Onest audit's
`onest-production-api-deploy` role stay tightly scoped independent of
whatever `GitHubActions-platform-infra` was doing.

---

## Anti-patterns (do not do these)

- **Wildcard `sub` across an entire org or arbitrary ref.**
  `StringLike` on `repo:org/*` (any repo in the org) or `repo:ORG/REPO:*`
  (any ref/workflow in one repo) lets ANY workflow on ANY matching ref in
  scope assume the role — including a future workflow nobody has reviewed
  yet against the current permissions policy. This was the Onest audit's
  §4.8 finding (`GitHubActions-platform-infra`'s trust: broad, undocumented)
  — not fixed as of the audit, flagged as a conscious-decision gap.
- **Sharing one role across repos or environments.** A single role trusted
  for both `repo:ORG/app:ref:refs/heads/main` and
  `repo:ORG/infra:ref:refs/heads/main` conflates two blast radii that should
  never be conflated — a compromised app-repo workflow could then reach
  whatever the infra role can touch.
- **Standing static AWS credentials as a "temporary" bridge to OIDC.** The
  audit's §1.4/§4.7 finding — a full-`AdministratorAccess` IAM user with an
  *active* access key, only mitigated (not eliminated) by an MFA-conditional
  deny policy — is exactly the risk class OIDC exists to remove. This repo's
  own `aws-credentials-ban.yml` gate (HARD BLOCK on
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` refs and
  `aws-access-key-id:`/`aws-secret-access-key:` parameters anywhere in
  `.github/workflows/`) is the enforcement backstop — see
  [`docs/GATE-EVIDENCE.md`](GATE-EVIDENCE.md).
- **Trusting a branch `ref` when a `job_workflow_ref` or GitHub Environment
  scope would be tighter and is available.** Branch-level trust means every
  workflow file that can run on that branch can assume the role, not just
  the one deploy workflow that's supposed to.

## Why this belongs in Orbit, not each product's own docs

Orbit already owns the enforcement side (`aws-credentials-ban.yml` bans
static keys); this doc owns the corresponding OIDC *correctness* side so a
product wiring its first deploy role has one canonical reference instead of
re-deriving trust-policy scoping from scratch or copying whatever the last
product happened to write. See [`build-push-sha.yml`](../.github/workflows/build-push-sha.yml)
for the Orbit engine that consumes a role provisioned this way (its
`oidc_role_arn` input takes the role ARN — a non-secret value; this doc is
what makes handing that ARN to a workflow safe).
