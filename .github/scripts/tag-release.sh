#!/usr/bin/env bash
set -euo pipefail

RELEASE_BRANCH="${RELEASE_BRANCH:-prod-release}"
ATTEMPTS="${ATTEMPTS:-3}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for attempt in $(seq 1 "${ATTEMPTS}"); do
  git fetch --quiet --tags --force origin main "${RELEASE_BRANCH}"

  latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)"

  if [ -z "${latest}" ]; then
    next="v0.1.0"
  else
    IFS=. read -r major minor patch <<<"${latest#v}"
    next="v${major}.${minor}.$(( patch + 1 ))"
  fi

  target="$(git rev-parse "origin/${RELEASE_BRANCH}")"

  if existing="$(git tag --points-at "${target}" --list 'v[0-9]*.[0-9]*.[0-9]*' | head -n 1)" \
     && [ -n "${existing}" ]; then
    echo "${RELEASE_BRANCH} is already tagged ${existing}, nothing to do"
    exit 0
  fi

  image_tag="$(git show "${target}:k8s/base/kustomization.yaml" \
    | yq '(.images[] | select(.name == "practice-backend") | .newTag) // ""')"
  if [ -z "${image_tag}" ]; then
    echo "::error::could not read the image tag at ${target} to annotate ${next}"
    exit 1
  fi

  git tag -a "${next}" "${target}" \
    -m "Release ${next}" \
    -m "prod image: ${image_tag}"

  if git push origin "refs/tags/${next}"; then
    echo "tagged ${target} as ${next} (prod image ${image_tag})"
    echo "::notice::released ${next} running ${image_tag}"
    exit 0
  fi

  echo "tag ${next} rejected, recomputing (attempt ${attempt}/${ATTEMPTS})"
  git tag -d "${next}" >/dev/null
  if [ "${attempt}" -lt "${ATTEMPTS}" ]; then
    sleep $(( attempt * 5 ))
  fi
done

echo "::error::failed to tag the release after ${ATTEMPTS} attempts (prod IS promoted; tag by hand)"
exit 1
