#!/usr/bin/env bash
#
# Pin the staging overlay to $TAG and land that commit on origin/main.
#
# Called by the deploy-staging job in build-and-deploy.yml. Expects a full
# checkout (fetch-depth: 0), kustomize on PATH, and a token that can push to
# main. Reads:
#   REGISTRY -- ECR registry host
#   TAG      -- image tag to pin, produced by the build job
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"
: "${TAG:?TAG is required}"

ATTEMPTS="${ATTEMPTS:-5}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

pin_and_commit() {
  # Checked explicitly rather than left to set -e: this function is called as
  # `if ! pin_and_commit`, which suspends set -e for its whole body. A failed
  # kustomize would otherwise leave the tree clean and get misread below as
  # "already pinned" -- a green run over unpinned staging. Not retryable.
  if ! (
    cd k8s/overlays/staging
    kustomize edit set image \
      "practice-backend=${REGISTRY}/practice-backend:${TAG}" \
      "practice-frontend=${REGISTRY}/practice-frontend:${TAG}"
  ); then
    echo "::error::kustomize edit set image failed for ${TAG}"
    exit 1
  fi
  if git diff --quiet -- k8s/overlays/staging; then
    echo "staging already on ${TAG}, nothing to commit"
    return 1
  fi
  git add k8s/overlays/staging/kustomization.yaml
  git commit -m "deploy(staging): ${TAG} [skip ci]"
}

# The build ran at the triggering SHA, so main may have moved on -- on a
# re-run, or on two pushes in quick succession. The concurrency group stops
# this workflow racing itself, but not a human pushing to main between our
# fetch and our push.
#
# Rather than rebasing our commit onto whatever landed (which stops dirty if
# someone else touched the same kustomization.yaml), throw our commit away
# each round and rebuild it on top of the newest origin/main. pin_and_commit
# is a pure function of $TAG and the tree, so the rebuilt commit is identical
# minus the parent.
for attempt in $(seq 1 "${ATTEMPTS}"); do
  git fetch --quiet origin main
  git reset --hard --quiet origin/main

  # Mid-loop this means someone else's run already pinned $TAG -- the desired
  # state is on main, which is the outcome we wanted.
  if ! pin_and_commit; then
    echo "origin/main already pinned to ${TAG}"
    exit 0
  fi

  if git push origin HEAD:main; then
    echo "pinned staging to ${TAG} (attempt ${attempt}/${ATTEMPTS})"
    exit 0
  fi

  echo "push rejected, main moved (attempt ${attempt}/${ATTEMPTS})"
  if [ "${attempt}" -lt "${ATTEMPTS}" ]; then
    sleep $(( attempt * 5 ))
  fi
done

# Losing every race in a row is not contention, it is something wrong -- a
# branch protection rule, a revoked token, a push loop. Failing loudly beats
# a green check on an unpinned staging.
echo "::error::failed to pin staging to ${TAG} after ${ATTEMPTS} attempts"
exit 1
