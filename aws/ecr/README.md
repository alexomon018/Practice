# ECR policies

Applied by hand from this directory. Nothing reconciles these files against
AWS, so a change here is not live until the matching command below is run.

## Files

| File | Applied with |
|---|---|
| `github-oidc-trust.json` | `aws iam update-assume-role-policy --role-name github-actions-ecr-push --policy-document file://aws/ecr/github-oidc-trust.json` |
| `github-push-policy.json` | `aws iam put-role-policy --role-name github-actions-ecr-push --policy-name ecr-push --policy-document file://aws/ecr/github-push-policy.json` |
| `lifecycle-policy.json` | `aws ecr put-lifecycle-policy --repository-name practice-backend --lifecycle-policy-text file://aws/ecr/lifecycle-policy.json` (repeat for `practice-frontend`) |
| `repo-policy.json` | `aws ecr set-repository-policy --repository-name practice-backend --policy-text file://aws/ecr/repo-policy.json` (repeat for `practice-frontend`) |

## Why the trust policy lists two `sub` forms per branch

GitHub issues OIDC tokens with either the human-readable `owner/repo` subject
or the immutable-ID form (`owner@<account-id>/repo@<repo-id>`), depending on
repository settings. Listing only one means a settings change silently breaks
CI with a bare "Not authorized" from STS. Both `main` and `develop` are
listed: `main` builds staging and promotes prod, `develop` builds dev.

A tag-triggered release workflow would need its own entry
(`:ref:refs/tags/*`). The current trust covers branch refs only.

## Why the lifecycle keeps 100 images

JSON has no comments and ECR caps `description` at 255 characters, so the
reasoning lives here.

The budget was 30, sized for a single branch. Two branches now build on every
merge, roughly doubling the burn rate. More importantly, prod can sit on one
tag for weeks while dev and staging keep pushing — so the retention window has
to outlast the slowest promotion, not the fastest build. An image evicted out
from under a running prod deployment turns any pod reschedule into
`ImagePullBackOff` with no code change to blame.

The usual fix — a protected moving `prod` tag — is unavailable here: both
repositories are `IMMUTABLE`, which is also what makes a SHA tag a trustworthy
promotion identifier. Raising the count is the tradeoff that buys.

100 at 2 builds per merge is roughly 50 merges of headroom. If promotions ever
lag that far behind, raise it again rather than reaching for mutable tags.
