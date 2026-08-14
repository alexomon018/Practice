#!/usr/bin/env bash
set -euo pipefail

RELEASE_BRANCH="${RELEASE_BRANCH:-prod-release}"
: "${TARGET_SHA:?TARGET_SHA is required}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch --quiet origin main

current=""
if git fetch --quiet origin "${RELEASE_BRANCH}" 2>/dev/null; then
  current="$(git rev-parse FETCH_HEAD)"
fi

target="$(git rev-parse "${TARGET_SHA}^{commit}")"

if [ "${target}" = "${current}" ]; then
  echo "prod is already on ${target}, nothing to promote"
  exit 0
fi

if ! git merge-base --is-ancestor "${target}" origin/main; then
  echo "::error::${target} is not an ancestor of origin/main; refusing to promote"
  exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -n "${current}" ]; then
  before="$(mktemp)"; after="$(mktemp)"; wt="$(mktemp -d)/wt"

  git worktree add --quiet --detach "${wt}" "${current}"
  kustomize build "${wt}/k8s/overlays/prod" > "${before}"
  git worktree remove --force "${wt}"

  git worktree add --quiet --detach "${wt}" "${target}"
  kustomize build "${wt}/k8s/overlays/prod" > "${after}"
  git worktree remove --force "${wt}"

  {
    echo "## Promoting prod: \`${current:0:7}\` → \`${target:0:7}\`"
    echo
    echo '```diff'
    diff -u "${before}" "${after}" || true
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [ -n "${current}" ]; then
  push_args=(--force-with-lease="refs/heads/${RELEASE_BRANCH}:${current}")
else
  push_args=()
fi

if git push "${push_args[@]}" origin "${target}:refs/heads/${RELEASE_BRANCH}"; then
  echo "promoted prod: ${current:0:7}${current:+ -> }${target:0:7}"
  echo "::notice::prod now tracks ${RELEASE_BRANCH} at ${target:0:7}"
  exit 0
fi

echo "::error::failed to move ${RELEASE_BRANCH} to ${target}; it moved under us"
exit 1
