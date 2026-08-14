#!/usr/bin/env bash
#
# Pin the $OVERLAY overlay to an image tag and land that commit on origin/main.
#
# Called by the deploy jobs in deploy-dev.yml and deploy.yml. Expects a full
# checkout (fetch-depth: 0), kustomize on PATH, and a token that can push to
# main. Reads:
#   REGISTRY       -- ECR registry host
#   OVERLAY        -- overlay directory under k8s/overlays to pin
#   TAG            -- image tag to pin, produced by the build job
#   SOURCE_OVERLAY -- optional. When set, $TAG is ignored and the tag is read
#                     out of that overlay instead. This is promotion: prod is
#                     pinned to the artifact staging is already running, never
#                     to a fresh build of the same source.
#
# Every pin commit lands on main regardless of which branch triggered the
# build. main is the single source of truth all three Argo Applications read;
# the branch only decides which overlay gets written.
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"
: "${OVERLAY:?OVERLAY is required}"

ATTEMPTS="${ATTEMPTS:-5}"
SOURCE_OVERLAY="${SOURCE_OVERLAY:-}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Read the tag currently pinned in an overlay. Called before the retry loop,
# on a tree freshly reset to origin/main, so the value it returns is the tag
# that overlay is actually running right now.
#
# Everything diagnostic goes to stderr: stdout is the return channel and any
# stray echo lands inside the captured tag.
read_source_tag() {
  local overlay_dir="k8s/overlays/$1"
  local kfile="${overlay_dir}/kustomization.yaml"
  local backend frontend

  if [ ! -f "${kfile}" ]; then
    echo "::error::no kustomization.yaml in ${overlay_dir}" >&2
    exit 1
  fi

  # No -r: mikefarah yq v4 already prints scalars raw, and -r is not portable
  # across its v4 point releases. Parsed, not grepped -- this file is machine
  # written but hand readable, and its formatting will drift.
  backend="$(yq '(.images[] | select(.name == "practice-backend") | .newTag) // ""' "${kfile}")"
  frontend="$(yq '(.images[] | select(.name == "practice-frontend") | .newTag) // ""' "${kfile}")"

  # yq prints an empty string and exits 0 when the path does not match, so
  # set -e never fires. An empty tag would pin `practice-backend:` -- a
  # reference that looks valid to kustomize and is unpullable to the kubelet.
  if [ -z "${backend}" ] || [ -z "${frontend}" ]; then
    echo "::error::could not read both image tags from ${kfile}" >&2
    exit 1
  fi

  # Every pin writes both tags in one kustomize call, so these are equal under
  # all normal operation. Disagreement means a pin landed half-applied or
  # someone hand-edited the file. Promotion runs after a human already clicked
  # Approve and they will not see which one we picked, so guessing here ships
  # an artifact nobody signed off on. Refuse instead.
  if [ "${backend}" != "${frontend}" ]; then
    echo "::error::${1} tags disagree (backend=${backend} frontend=${frontend}); refusing to promote" >&2
    exit 1
  fi

  echo "${backend}"
}

if [ -n "${SOURCE_OVERLAY}" ]; then
  # Promotion mode reads from the tree, so the tree has to be current first.
  # The retry loop below resets again; this early fetch only exists so the
  # tag we resolve is not whatever the runner happened to check out.
  git fetch --quiet origin main
  git reset --hard --quiet origin/main
  TAG="$(read_source_tag "${SOURCE_OVERLAY}")"
  echo "promoting ${SOURCE_OVERLAY} -> ${OVERLAY} at ${TAG}"
fi

: "${TAG:?TAG is required (or set SOURCE_OVERLAY to promote)}"

pin_and_commit() {
  # Checked explicitly rather than left to set -e: this function is called as
  # `if ! pin_and_commit`, which suspends set -e for its whole body. A failed
  # kustomize would otherwise leave the tree clean and get misread below as
  # "already pinned" -- a green run over an unpinned overlay. Not retryable.
  if ! (
    cd "k8s/overlays/${OVERLAY}"
    kustomize edit set image \
      "practice-backend=${REGISTRY}/practice-backend:${TAG}" \
      "practice-frontend=${REGISTRY}/practice-frontend:${TAG}"
  ); then
    echo "::error::kustomize edit set image failed for ${TAG}"
    exit 1
  fi
  if git diff --quiet -- "k8s/overlays/${OVERLAY}"; then
    echo "${OVERLAY} already on ${TAG}, nothing to commit"
    return 1
  fi
  git add "k8s/overlays/${OVERLAY}/kustomization.yaml"
  git commit -m "deploy(${OVERLAY}): ${TAG} [skip ci]"
}

# The build ran at the triggering SHA, so main may have moved on -- on a
# re-run, or on two pushes in quick succession. The concurrency group stops
# this workflow racing itself, but not a human pushing to main between our
# fetch and our push, and not the dev and staging pipelines pinning their own
# overlays at the same time.
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
    echo "origin/main already pinned ${OVERLAY} to ${TAG}"
    exit 0
  fi

  if git push origin HEAD:main; then
    echo "pinned ${OVERLAY} to ${TAG} (attempt ${attempt}/${ATTEMPTS})"
    exit 0
  fi

  echo "push rejected, main moved (attempt ${attempt}/${ATTEMPTS})"
  if [ "${attempt}" -lt "${ATTEMPTS}" ]; then
    sleep $(( attempt * 5 ))
  fi
done

# Losing every race in a row is not contention, it is something wrong -- a
# branch protection rule, a revoked token, a push loop. Failing loudly beats
# a green check on an unpinned overlay.
echo "::error::failed to pin ${OVERLAY} to ${TAG} after ${ATTEMPTS} attempts"
exit 1
