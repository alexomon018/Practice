#!/usr/bin/env bash
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"
: "${TAG:?TAG is required}"
: "${BRANCH:?BRANCH is required}"

ATTEMPTS="${ATTEMPTS:-5}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

emit_sha() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "sha=$(git rev-parse HEAD)" >> "${GITHUB_OUTPUT}"
  fi
}

pin_and_commit() {
  if ! (
    cd k8s/base
    kustomize edit set image \
      "practice-backend=${REGISTRY}/practice-backend:${TAG}" \
      "practice-frontend=${REGISTRY}/practice-frontend:${TAG}"
  ); then
    echo "::error::kustomize edit set image failed for ${TAG}"
    exit 1
  fi

  if git diff --quiet -- k8s/base/kustomization.yaml; then
    echo "base is already on ${TAG}, nothing to commit"
    return 1
  fi

  git add k8s/base/kustomization.yaml
  git commit -m "deploy: ${TAG} [skip ci]"
}

for attempt in $(seq 1 "${ATTEMPTS}"); do
  git fetch --quiet origin "${BRANCH}"
  git reset --hard --quiet "origin/${BRANCH}"

  if ! pin_and_commit; then
    echo "origin/${BRANCH} is already pinned to ${TAG}"
    emit_sha
    exit 0
  fi

  if git push origin "HEAD:${BRANCH}"; then
    echo "pinned ${BRANCH} to ${TAG} (attempt ${attempt}/${ATTEMPTS})"
    emit_sha
    exit 0
  fi

  echo "push rejected, ${BRANCH} moved (attempt ${attempt}/${ATTEMPTS})"
  if [ "${attempt}" -lt "${ATTEMPTS}" ]; then
    sleep $(( attempt * 5 ))
  fi
done

echo "::error::failed to pin ${BRANCH} to ${TAG} after ${ATTEMPTS} attempts"
exit 1
