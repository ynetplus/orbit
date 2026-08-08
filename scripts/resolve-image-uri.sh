#!/usr/bin/env bash
# Orbit — resolve the SHA-immutable image URI for build-push-sha.yml.
#
# Extracted into its own script (Tier-2-engine style, matching
# scripts/supply-run.sh / scripts/semgrep-run.sh) so self-test.yml can
# exercise the exact same logic the real workflow runs, with fixture inputs
# and no AWS/ECR credentials — the "compiled plan/inputs/outputs contract"
# self-test (CR-A079-15).
#
# Usage: resolve-image-uri.sh <ecr_repository> <registry> <sha>
#   ecr_repository — bare repo name, or an already-qualified "<registry>/<repo>" URI
#   registry       — the ECR registry host (e.g. from aws-actions/amazon-ecr-login's
#                     `registry` output); ignored if ecr_repository already contains it
#   sha            — the commit SHA to tag with (the ONLY tag ever produced)
#
# Prints the resolved "<registry>/<repo>:<sha>" URI to stdout. Never emits a
# mutable tag (`latest`, `{env}-latest`, or any tag other than the given SHA).
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <ecr_repository> <registry> <sha>" >&2
  exit 2
fi

ECR_REPOSITORY="$1"
REGISTRY="$2"
SHA="$3"

if [[ "$ECR_REPOSITORY" == *"$REGISTRY"* ]]; then
  REPO_URI="$ECR_REPOSITORY"
else
  REPO_URI="${REGISTRY}/${ECR_REPOSITORY}"
fi

echo "${REPO_URI}:${SHA}"
