#!/usr/bin/env bash
#
# Tag the current prod promotion on main with the next patch version.
#
# Called by the promote-prod job in deploy.yml, after pin-overlay.sh has landed
# the promotion commit. Expects a full checkout (fetch-depth: 0), yq on PATH,
# and a token that can push tags. Reads:
#   OVERLAY -- overlay whose image tag the annotation records. Defaults to prod.
#
# The SHA tag in the overlay is precise but unreadable: "prod is on 0906ed5"
# answers nothing a human asked. A version tag gives releases names, and makes
# `git log v0.2.0..v0.3.0` a changelog.
#
# The series is steered by hand, not configured. This script only ever bumps
# the patch component of the highest existing vX.Y.Z tag, so a minor or major
# release is `git tag v0.2.0 && git push origin v0.2.0` before the next
# promotion -- the bump after that continues from v0.2.1. That keeps the
# unattended path decision-free without hardcoding a release cadence.
set -euo pipefail

OVERLAY="${OVERLAY:-prod}"
ATTEMPTS="${ATTEMPTS:-3}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for attempt in $(seq 1 "${ATTEMPTS}"); do
  # --force so a tag deleted and recreated upstream does not leave this clone
  # believing the old one, which would compute a version that already exists.
  git fetch --quiet --tags --force origin main

  # Sorting is delegated to git's version-aware comparator. A lexical sort puts
  # v0.9.0 above v0.10.0, which would silently reissue an existing version.
  latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)"

  if [ -z "${latest}" ]; then
    next="v0.1.0"
  else
    IFS=. read -r major minor patch <<<"${latest#v}"
    next="v${major}.${minor}.$(( patch + 1 ))"
  fi

  target="$(git rev-parse origin/main)"

  # Promotion is idempotent -- pin-overlay.sh exits clean when prod is already
  # on the tag -- so this has to be too, or a re-run mints a second version for
  # a release that never changed.
  if existing="$(git tag --points-at "${target}" --list 'v[0-9]*.[0-9]*.[0-9]*' | head -n 1)" \
     && [ -n "${existing}" ]; then
    echo "origin/main is already tagged ${existing}, nothing to do"
    exit 0
  fi

  image_tag="$(yq '(.images[] | select(.name == "practice-backend") | .newTag) // ""' \
    "k8s/overlays/${OVERLAY}/kustomization.yaml")"
  if [ -z "${image_tag}" ]; then
    echo "::error::could not read the ${OVERLAY} image tag to annotate ${next}"
    exit 1
  fi

  git tag -a "${next}" "${target}" \
    -m "Release ${next}" \
    -m "${OVERLAY} image: ${image_tag}"

  if git push origin "refs/tags/${next}"; then
    echo "tagged ${target} as ${next} (${OVERLAY} image ${image_tag})"
    echo "::notice::released ${next} running ${image_tag}"
    exit 0
  fi

  # Almost always another promotion claimed this version between our read and
  # our push. Drop the local tag so the next round recomputes from the tag list
  # as it now stands rather than retrying the same name forever.
  echo "tag ${next} rejected, recomputing (attempt ${attempt}/${ATTEMPTS})"
  git tag -d "${next}" >/dev/null
  if [ "${attempt}" -lt "${ATTEMPTS}" ]; then
    sleep $(( attempt * 5 ))
  fi
done

# The deploy-prod concurrency group means we should never lose this race more
# than momentarily. Losing it repeatedly is a protection rule or a revoked
# token, not contention -- and prod is already promoted at this point, so
# failing here reports an untagged release rather than a failed one.
echo "::error::failed to tag the release after ${ATTEMPTS} attempts (prod IS promoted; tag by hand)"
exit 1
