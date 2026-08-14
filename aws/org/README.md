# AWS Organization setup

Org `o-wu17xrito2`, three workload accounts, one management account, no Control Tower.

| Account        | ID           | Purpose                                      |
| -------------- | ------------ | -------------------------------------------- |
| a.mitic        | 608108316712 | Management: Organizations, Identity Center, billing |
| Infrastructure | 213851292053 | Shared container registry, CI identity        |
| Dev            | 461415799375 | Dev cluster, currently still holds ECR        |
| Staging        | 439996178694 | Staging cluster                               |
| Prod           | 840080484810 | Prod cluster                                  |

## Status

Verified against the live org.

Done:

- [x] Org on `FeatureSet: ALL`
- [x] Identity Center user `Aleksa` in group with `AdministratorAccess` on the management account
- [x] CLI profile `admin` reaching 608108316712
- [x] OUs `Workloads`, `NonProd`, `Prod`, `Infrastructure` created
- [x] Dev + Staging in NonProd, Prod in Prod OU
- [x] Control Tower leftovers (`Sandbox`, `Security` OUs) deleted, no landing zone, no stack sets
- [x] SCP policy type `ENABLED` on `r-85of`, `FullAWSAccess` auto-attached throughout
- [x] `baseline` SCP `p-cy0gu4lz` attached to Workloads `ou-85of-shj9oijj` and Infrastructure
      `ou-85of-yz63u0h6`, region lock verified from Dev
- [x] Infrastructure account `213851292053` created and moved into `ou-85of-yz63u0h6`
- [x] `PlatformAdmins` group with `AdministratorAccess` on the Infrastructure account, `infra`
      CLI profile working
- [x] Registry stood up in `213851292053`: GitHub OIDC provider, `github-actions-ecr-push`
      role, `practice-backend` and `practice-frontend` with `IMMUTABLE` tags, scan-on-push,
      org-wide pull via `aws:PrincipalOrgID`
- [x] Workflow rewired to the new registry and role ARN

Remaining, in order:
- [ ] **5.** Push the workflow change, confirm the build pushes to `213851292053` and staging
      pulls from it. Section 5.5.
- [ ] **6.** Promote prod onto the new registry via a reviewed PR. Prod still points at the dev
      registry and pins `0.1.0`, which does not exist in the new one — the next normal
      promotion carries it across. Do not hand-edit `newName` ahead of that.
- [ ] **7.** Only once prod is promoted: delete the dev-account repos and
      `aws/ecr-cross-account-policy.json`. Section 5.7.
- [ ] **7.** Fill in the prod guardrails — `TODO(human)` in `aws/org/scp-prod.json`. Blocks 8.
- [ ] **8.** Create the `prod` SCP, attach to `ou-85of-dipikjaf`. Section 2.
- [ ] **9.** Baseline services: org CloudTrail, GuardDuty delegated admin, cost anomaly monitor,
      per-account budgets. Section 4.
- [ ] **10.** `ProdBreakGlass` permission set + group + the CloudTrail metric filter that alarms
      on its use. Section 3.
- [ ] **11.** Enrol MFA on the `Aleksa` Identity Center user. It holds admin on the one account
      SCPs cannot constrain.

The registry move (3–6) deliberately comes before the prod SCP (7–8): the prod ceiling denies
`ecr:PutImage`, and you do not want to be debugging a registry cutover and a new deny at the
same time.

Longer term, not blocking:

- [ ] Migrate the workloads sitting in the management account (CDK assets, Elastic Beanstalk,
      `supwr.click`, textract, terraform state) into a member account. Anything there runs
      permanently outside every guardrail in this document.
- [ ] Correct the stale comment in `k8s/overlays/staging/kustomization.yaml` — CI rewrites
      `newName` as well as `newTag`, because the workflow passes a full image reference.
- [ ] Decide whether `aleksa-administrator`, the IAM user in the management account, stays as
      console-only break-glass or gets deleted now that Identity Center works.

## 0. Bootstrap the admin path

Everything below is API-driven. None of it should run under root access keys: SCPs do not
apply to the management account, so management-account root is the one identity the org's
guardrails structurally cannot constrain. Use root exactly once, in the console, to create a
non-root path, then stop.

Check whether a path already exists before reaching for root:

```
aws sts get-caller-identity --profile aleksa-teraform
aws organizations describe-organization --profile aleksa-teraform
```

If those are denied, log into the management account console as root with MFA and do only
this, then log out:

1. Create an `AdministratorAccess` permission set in Identity Center.
2. Assign it to your user on account `608108316712`.
3. Confirm no root access keys exist under Security Credentials; delete any that do.

From then on everything is CLI. Add the profile:

```
aws configure sso --profile mgmt-admin
aws sso login --profile mgmt-admin
```

Once the org has all-features enabled, strip root credentials from the member accounts too:

```
aws organizations enable-aws-service-access --service-principal iam.amazonaws.com
aws iam list-organizations-features
aws iam enable-organizations-root-credentials-management
```

Every command in the sections below assumes `--profile mgmt-admin`.

## 1. OU layout

Org `o-wu17xrito2`, root `r-85of`.

```
Root  r-85of
├── Infrastructure   ou-85of-yz63u0h6   shared services (ECR, CI identity)
├── Workloads        ou-85of-shj9oijj
│   ├── NonProd      ou-85of-1inrmvve   Dev 461415799375, Staging 439996178694
│   └── Prod         ou-85of-dipikjaf   Prod 840080484810
└── a.mitic          608108316712       management account, stays at root
```

The split exists so SCPs have somewhere to attach. `NonProd` and `Prod` get different
policy sets; that is the whole reason Prod is not just another account under `Workloads`.

The management account is never moved into an OU, and SCPs never apply to it regardless.

`Sandbox` and `Security` were Control Tower leftovers and have been deleted. If a Security
OU is wanted later for log-archive and audit accounts, it is one `create-organizational-unit`
call away.

Recover the child OU IDs in a new shell:

```
aws organizations list-organizational-units-for-parent --parent-id ou-85of-shj9oijj --query 'OrganizationalUnits[].[Name,Id]' --output text
```

The management account is never moved into an OU. It stays at the root, and SCPs do not
apply to it wherever it sits. Only Dev, Staging and Prod get moved.

Confirm you are in the management account before starting:

```
export AWS_PROFILE=admin
aws sso login
aws sts get-caller-identity --query Account --output text
```

That must print `608108316712`. Then create the two missing OUs. `Security` and `Sandbox`
already exist, so this only adds `Workloads` and `Infrastructure`:

```
ROOT_ID=r-85of
WORKLOADS=$(aws organizations create-organizational-unit --parent-id "$ROOT_ID" --name Workloads --query 'OrganizationalUnit.Id' --output text)
NONPROD=$(aws organizations create-organizational-unit --parent-id "$WORKLOADS" --name NonProd --query 'OrganizationalUnit.Id' --output text)
PROD_OU=$(aws organizations create-organizational-unit --parent-id "$WORKLOADS" --name Prod --query 'OrganizationalUnit.Id' --output text)
INFRA=$(aws organizations create-organizational-unit --parent-id "$ROOT_ID" --name Infrastructure --query 'OrganizationalUnit.Id' --output text)
printf 'workloads=%s nonprod=%s prod=%s infra=%s\n' "$WORKLOADS" "$NONPROD" "$PROD_OU" "$INFRA"
```

Move the three workload accounts:

```
aws organizations move-account --account-id 461415799375 --source-parent-id "$ROOT_ID" --destination-parent-id "$NONPROD"
aws organizations move-account --account-id 439996178694 --source-parent-id "$ROOT_ID" --destination-parent-id "$NONPROD"
aws organizations move-account --account-id 840080484810 --source-parent-id "$ROOT_ID" --destination-parent-id "$PROD_OU"
```

Verify:

```
aws organizations list-accounts-for-parent --parent-id "$NONPROD" --query 'Accounts[].[Id,Name]' --output table
aws organizations list-accounts-for-parent --parent-id "$PROD_OU" --query 'Accounts[].[Id,Name]' --output table
```

The OU IDs live only in that shell. To recover them in a later session:

```
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
aws organizations list-organizational-units-for-parent --parent-id "$ROOT_ID" --query 'OrganizationalUnits[].[Name,Id]' --output text
```

### Infrastructure account

Closes the ECR gap described at the bottom of this file. Account creation is async:

```
REQ=$(aws organizations create-account --email aleksa.mitic5859+infra@gmail.com --account-name Infrastructure --query 'CreateAccountStatus.Id' --output text)
aws organizations describe-create-account-status --create-account-request-id "$REQ" --query 'CreateAccountStatus.[State,AccountId]' --output text
```

Poll the second command until `State` is `SUCCEEDED`, then move it:

```
INFRA_ACCT=$(aws organizations describe-create-account-status --create-account-request-id "$REQ" --query 'CreateAccountStatus.AccountId' --output text)
aws organizations move-account --account-id "$INFRA_ACCT" --source-parent-id "$ROOT_ID" --destination-parent-id "$INFRA"
```

The new account has no Identity Center assignment yet. Grant yourself `PowerUserAccess` on it
before trying to use it, the same way section 3 describes.

## 2. Service control policies

SCPs never apply to the management account. They are a ceiling, not a grant: an Allow in an
SCP does not give permission, it only stops the Deny from applying.

Enabling the policy type makes AWS auto-attach `FullAWSAccess` to every OU and account.
Never detach it. SCPs are deny-by-default, `FullAWSAccess` is the `Allow *` that opens the
gate, and these policies carve Denies out of it.

Check whether it is already on:

```
aws organizations list-roots --query 'Roots[0].PolicyTypes' --output table
aws organizations enable-policy-type --root-id "$ROOT_ID" --policy-type SERVICE_CONTROL_POLICY
```

Create the baseline and attach it to the Workloads OU, not the root. Same coverage for the
three workload accounts, but Sandbox, Security and the management account stay untouched
while you verify nothing breaks. Run from the repo root:

```
BASELINE=$(aws organizations create-policy --type SERVICE_CONTROL_POLICY --name baseline --description "Org-wide floor" --content file://aws/org/scp-baseline.json --query 'Policy.PolicySummary.Id' --output text)
aws organizations attach-policy --policy-id "$BASELINE" --target-id "$WORKLOADS"
aws organizations list-policies-for-target --target-id 461415799375 --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output table
```

`scp-baseline.json` blocks: leaving the org, root-user actions, tampering with
CloudTrail/GuardDuty/Config, and any region except us-east-1.

Verify from Dev before going further. The first call must fail, the second must succeed:

```
aws ec2 describe-vpcs --region eu-central-1 --profile aleksa-tera
aws ec2 describe-vpcs --region us-east-1 --profile aleksa-tera
```

To roll back, detach. The policy survives, it just stops applying:

```
aws organizations detach-policy --policy-id "$BASELINE" --target-id "$WORKLOADS"
```

Once verified, attach `scp-prod.json` to the Prod OU on top of the baseline.

### Prod OU guardrails

`scp-prod.json` currently only protects the deploy role from being rewritten. It needs the
rest of the prod-specific ceiling — see `TODO(human)` in that file.

## 3. Access via Identity Center

Groups, not direct user assignments. Even as a single operator, group membership is what you
revoke later without hunting through per-account assignments.

Groups answer "who is this", permission sets answer "what can they do here". One group can
carry a different permission set per account, which is why `Developers` covers three accounts
with three different levels.

| Group            | Dev       | Staging   | Prod              | Infrastructure | Management    |
| ---------------- | --------- | --------- | ----------------- | -------------- | ------------- |
| `Developers`     | PowerUser | PowerUser | ReadOnly          | —              | —             |
| `PlatformAdmins` | —         | —         | —                 | Administrator  | —             |
| `OrgAdmins`      | —         | —         | —                 | —              | Administrator |
| `ProdBreakGlass` | —         | —         | Administrator, 1h | —              | —             |

`PlatformAdmins` is deliberately separate from `OrgAdmins`. Registry administration happens
routinely; management-account administration should be rare and deliberate. Blending them
means every ECR command runs under an identity that can also delete accounts, and CloudTrail
can no longer tell the two kinds of work apart.

| Permission set        | Policy              | Session |
| --------------------- | ------------------- | ------- |
| `AdministratorAccess` | AWS managed         | 1h      |
| `PowerUserAccess`     | AWS managed         | 8h      |
| `ReadOnlyAccess`      | AWS managed         | 8h      |
| `ProdBreakGlass`      | AdministratorAccess | 1h      |

`PowerUserAccess` is `NotAction: ["iam:*", "organizations:*", "account:*"]`. It is right for
accounts where you consume infrastructure and wrong for any account where you build IAM.

`ProdBreakGlass` is the important one: prod stays read-only for everyday work, and elevation
is a deliberate, short, separately-logged act. Alarm on its use:

```
aws logs put-metric-filter --log-group-name <CLOUDTRAIL_LOG_GROUP> \
  --filter-name ProdBreakGlassUsed \
  --filter-pattern '{ $.userIdentity.sessionContext.sessionIssuer.userName = "AWSReservedSSO_ProdBreakGlass_*" }' \
  --metric-transformations metricName=ProdBreakGlassUsed,metricNamespace=Security,metricValue=1
```

Humans never hold write access to prod as a standing grant. Deployment writes come from the
Argo/CI role, not from a person.

## 4. Baseline services

Run from the management account, each needs the org to have all-features enabled:

```
aws organizations enable-all-features
aws cloudtrail create-trail --name org-trail --s3-bucket-name <BUCKET> --is-organization-trail --is-multi-region-trail
aws guardduty enable-organization-admin-account --admin-account-id <SECURITY_OR_PROD_ACCOUNT>
aws ce create-anomaly-monitor --anomaly-monitor '{"MonitorName":"org-wide","MonitorType":"DIMENSIONAL","MonitorDimension":"SERVICE"}'
```

Per-account budgets are worth 5 minutes; a forgotten NAT gateway in dev is the classic bill.

## 5. Shared container registry

Today `aws/ecr-cross-account-policy.json` shares the **dev** account's registry to staging and
prod. Prod therefore pulls images from an account where PowerUserAccess is a standing grant
and experiments run. The registry moves to a dedicated account in the Infrastructure OU:
GitHub OIDC pushes there, every account in the org pulls from there, nobody has PowerUser.

Policy documents live in `aws/ecr/`. The pull grant is scoped by `aws:PrincipalOrgID`, not by
an account list, so new accounts get access without editing anything.

### 5.1 Create the account

```
export AWS_PROFILE=admin
REQ=$(aws organizations create-account --email aleksa.mitic5859+infra@gmail.com --account-name Infrastructure --query 'CreateAccountStatus.Id' --output text)
aws organizations describe-create-account-status --create-account-request-id "$REQ" --query 'CreateAccountStatus.[State,AccountId]' --output text
```

Poll until `SUCCEEDED`, then move it into the Infrastructure OU:

```
INFRA_ACCT=$(aws organizations describe-create-account-status --create-account-request-id "$REQ" --query 'CreateAccountStatus.AccountId' --output text)
aws organizations move-account --account-id "$INFRA_ACCT" --source-parent-id r-85of --destination-parent-id ou-85of-yz63u0h6
echo "$INFRA_ACCT"
```

Assign yourself `AdministratorAccess` on it in Identity Center, then add a CLI profile:

```
aws configure sso --profile infra
```

`AdministratorAccess` rather than `PowerUserAccess`, because the managed PowerUser policy is
`NotAction: ["iam:*", ...]` and section 5.3 creates an OIDC provider, a role and a role policy.
The account is still bounded by the `baseline` SCP attached to its OU.

### 5.2 Fill the account ID into the policy documents

```
sed -i '' "s/INFRA_ACCOUNT_ID/$INFRA_ACCT/g" aws/ecr/github-oidc-trust.json aws/ecr/github-push-policy.json
```

### 5.3 GitHub OIDC push role, in the infra account

```
export AWS_PROFILE=infra
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
aws iam create-role --role-name github-actions-ecr-push --assume-role-policy-document file://aws/ecr/github-oidc-trust.json
aws iam put-role-policy --role-name github-actions-ecr-push --policy-name ecr-push --policy-document file://aws/ecr/github-push-policy.json
```

AWS no longer validates the thumbprint for GitHub's provider, but the CLI still requires the
argument.

### 5.4 Repositories

```
for repo in practice-backend practice-frontend; do
  aws ecr create-repository --repository-name "$repo" --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true
  aws ecr set-repository-policy --repository-name "$repo" --policy-text file://aws/ecr/repo-policy.json
  aws ecr put-lifecycle-policy --repository-name "$repo" --lifecycle-policy-text file://aws/ecr/lifecycle-policy.json
done
```

`IMMUTABLE` means a tag pinned in `k8s/overlays/prod/kustomization.yaml` can never be
repointed at different bytes after review. That is what makes tag-based promotion trustworthy.

### 5.5 Rewire the pipeline

Four references carry the old dev account ID:

| File | What changes |
| ---- | ------------ |
| `.github/workflows/build-and-deploy.yml` | `ECR_REGISTRY`, `role-to-assume` |
| `k8s/overlays/staging/kustomization.yaml` | both `newName` |
| `k8s/overlays/prod/kustomization.yaml` | both `newName` |

```
grep -rl 461415799375 .github k8s | xargs sed -i '' "s/461415799375/$INFRA_ACCT/g"
```

Dev is unaffected: it runs on kind with images loaded via `kind load docker-image`, so it has
no registry reference at all.

### 5.6 Pull-side permission

A repository policy cannot grant `ecr:GetAuthorizationToken` — that action is account-level.
Each cluster's node role needs it from its own side, which the managed
`AmazonEC2ContainerRegistryReadOnly` policy on EKS node roles already provides. If pulls fail
with an auth error despite the repo policy being correct, this is why.

### 5.7 Decommission the old registry

Only after a staging deploy has pulled successfully from the new registry:

```
export AWS_PROFILE=aleksa-tera
aws ecr delete-repository --repository-name practice-backend --force
aws ecr delete-repository --repository-name practice-frontend --force
```

Then delete `aws/ecr-cross-account-policy.json` from the repo.
