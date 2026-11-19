# eks-multiregion-gitops

The single source of truth for what runs in every cluster. Argo CD in each cluster reads this
repository and makes the cluster match it. Nothing else deploys.

This repository answers one question for each environment: **which version runs here?** The
answer is one line in one file, changed only by a reviewed pull request.

Related repositories: `eks-multiregion-infra` (Terraform and Ansible) builds the clusters and
installs Argo CD. `eks-multiregion-apps` holds the application's source and builds its images.

## Layout

```
charts/
  platform-apps/         the "app of apps": produces every Argo CD Application for a cluster
  platform-config/       namespaces, pod security, quotas, RBAC, Karpenter NodePools
  demo-web/              frontend tier: nginx. Deployment, Service, Ingress, NetworkPolicy
  demo-api/              backend tier: the API. Deployment or Argo Rollout, HPA, Vault secret
clusters/<cluster>/      per cluster: which add-ons are on, which environments it hosts
envs/
  dev/                   release.yaml = THE VERSION.  demo-web.yaml, demo-api.yaml = settings
  stg/
  prd/ap-southeast-2/    production, Sydney (primary region)
  prd/ap-southeast-1/    production, Singapore (standby region)
  local/                 a kind cluster on a laptop
scripts/
  promote.sh             move a version one step along the promotion order
  check-promotion.sh     the gate: refuses a version that skipped a stage
  render.sh              render everything Argo CD would apply, without a cluster
.github/
  CODEOWNERS             who must approve changes to each environment
  workflows/validate.yml required checks on every pull request
  workflows/promote.yml  opens the promotion pull request
```

## Build once, promote the same image

```
 apps repo: merge to main
      |  test, build, scan, push  ->  demo-web:a1b2c3d  demo-api:a1b2c3d   (built ONCE)
      v
 dev   envs/dev/release.yaml                 pull request by the bot, merges by itself
      |  promote stg
      v
 stg   envs/stg/release.yaml                 pull request, one developer approves
      |  promote prd-ap-southeast-2
      v
 prd   envs/prd/ap-southeast-2/release.yaml  pull request, a RELEASE APPROVER approves
      |                                      then a canary: 25 per cent, pause, a person promotes
      |  promote prd-ap-southeast-1
      v
 prd   envs/prd/ap-southeast-1/release.yaml  pull request, a release approver approves
```

The image is never rebuilt for a later environment. The tag is the commit, and tags are
immutable in ECR, so the bytes that passed in dev and stg are the bytes that reach production.
What differs between environments is configuration (replicas, release strategy, ingress),
which lives in the other files of each `envs/` folder.

## What controls a production release

Six controls, each closing a different gap:

| Control | What it stops | Where |
| --- | --- | --- |
| Pull request required on `main` | Anyone, including the bot, pushing a change straight in | Branch rule (set up below) |
| Code owners for `envs/prd/` | A production change merging without a release approver | `.github/CODEOWNERS` |
| The promotion gate | A version reaching stg that dev has not run, or prd that stg has not run, or Singapore before Sydney | `scripts/check-promotion.sh`, a required check |
| No tag input for stg or prd | Typing an arbitrary tag into a promotion | `scripts/promote.sh` |
| Argo CD AppProject `apps` | An application chart deploying outside its namespaces or creating cluster-wide objects | `charts/platform-apps/templates/projects.yaml` |
| Canary with a manual pause in prd Sydney | A bad version reaching every production pod at once | `envs/prd/ap-southeast-2/demo-api.yaml` |

And because the pipeline never holds cluster credentials, there is no way around Git: a
change made by hand in the cluster is undone by Argo CD (self-heal).

**Rollback** is `git revert` of the promotion commit, through a pull request. The gate would
refuse it (the older tag is no longer what stg runs), so add the label `rollback` to the pull
request: the gate then warns instead of failing. The release approver is still required.

**What a real production adds**: deploy by image digest rather than tag; sign images in CI
and verify the signature at admission (cosign with Kyverno); Argo CD sync windows to block
releases outside agreed hours; automated analysis in the canary (error rate from Prometheus)
instead of a person watching; and separate clusters and AWS accounts for dev, stg and prd.

## Environments and clusters

| Environment | Namespace | Cluster in this lab | In production |
| --- | --- | --- | --- |
| dev | `demo-dev` | Sydney | Its own cluster, non-production account |
| stg | `demo-stg` | Sydney | Its own cluster, shaped like production |
| prd | `demo` | Sydney and Singapore | Production account, both regions |

The lab puts dev and stg on the Sydney cluster as namespaces to save money. The Git layout
and the promotion flow do not change when they move to their own clusters: only the
`environments:` block in `clusters/<cluster>/platform.yaml` does.

## Three tiers

| Tier | What | Runs in | Accepts traffic from |
| --- | --- | --- | --- |
| Frontend | `demo-web`, nginx | frontend private subnets, on nodes labelled `tier=frontend` | The load balancer (VPC range) |
| Backend | `demo-api`, the API | backend private subnets, on nodes labelled `tier=backend` | Frontend pods only (NetworkPolicy) |
| Database | RDS PostgreSQL | database subnets, no route to the internet | Backend subnets only (security group) |

The backend gets the database's address and password from Vault, through External Secrets,
as files. The frontend has no Vault role and no path to the database.

## How the charts fit together

Ansible creates one Application by hand, `root`. It renders `charts/platform-apps`, which
produces every other Application, in waves:

| Wave | Applications | Why this order |
| --- | --- | --- |
| 0 | metrics-server, external-secrets, argo-rollouts, load balancer controller, Karpenter or Cluster Autoscaler, Velero | Controllers and the resource types (CRDs) they define |
| 1 | platform-config | Uses those types: NodePools, namespaces, RBAC |
| 2 | Vault, Prometheus stack | Need storage and the settings above |
| 3 | `demo-web-<env>` and `demo-api-<env>` for each environment the cluster hosts | Need all of it |

`root` receives a few facts about its cluster from Terraform, through Ansible (name, region,
registry, VPC range). Values in `charts/platform-apps/values.yaml` use them as
`{{ .Values.cluster.name }}`, so no account ID or resource ID is committed here.

## One-time setup on GitHub

1. **Release bot.** Create a GitHub App (Settings > Developer settings > GitHub Apps) with
   repository permissions Contents, Pull requests and Actions set to read and write. Install
   it on this repository only. Store its App ID and a private key as the secrets
   `RELEASE_BOT_APP_ID` and `RELEASE_BOT_PRIVATE_KEY` here and in the application repository.
   In the application repository also set the variable `GITOPS_REPO_NAME` to this
   repository's name.
2. **Code owners.** Replace the `@CHANGE-ME-...` placeholders in `.github/CODEOWNERS`.
3. **Branch rule on `main`** (Settings > Rules): require a pull request; require review from
   code owners; require the status checks `render` and `promotion-order`; allow auto-merge
   (Settings > General). Do not add the bot to the bypass list.

This setup has not been run end to end. Check on the first dev promotion that the pull
request merges by itself with no code owner on `envs/dev/`, and that a prd pull request waits.

## Using it

```
scripts/promote.sh status                 # what each stage runs
scripts/render.sh all                     # do the charts render for every cluster?
scripts/render.sh ap-southeast-2 | less   # everything Argo CD would apply to Sydney
```

Promote from Actions > **promote** > Run workflow, choosing the stage. Or locally: run
`scripts/promote.sh stg`, commit on a branch, open a pull request.

## Exercises

Choose the cluster first, then use plain `kubectl`:

```
kubectl config use-context lab-ap-southeast-2        # or lab-ap-southeast-1, or kind-mr-local
URL=http://$(kubectl -n demo get ingress demo-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s $URL/api/info | jq           # or open $URL in a browser
```

Without a load balancer (dev, stg, kind): `kubectl -n demo-dev port-forward svc/demo-web 8080:80`
and use `URL=http://localhost:8080`. The Rollouts commands need the kubectl plugin:
https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation

**1. Promote a version to production.** Merge a change in the application repository. Watch
the bot's pull request for dev merge by itself. Run promote for `stg`, approve, merge. Run
promote for `prd-ap-southeast-2`, approve as release approver, merge.

**2. Try to skip staging.** On a branch, put dev's tag straight into
`envs/prd/ap-southeast-2/release.yaml` and open a pull request. The `promotion-order` check
fails and names the stage you skipped.

**3. Canary release.** When a prd Sydney promotion merges:
```
kubectl argo rollouts get rollout demo-api -n demo --watch    # pauses at 25 per cent
kubectl argo rollouts promote demo-api -n demo                # continue, or:
kubectl argo rollouts abort demo-api -n demo                  # back to the old version
```
While it is paused, call `$URL/api/info` a few times: about one answer in four shows the new
version. stg runs the same canary with timed pauses, so the mechanism is rehearsed first.

**4. Blue-green.** Set `strategy: blueGreen` in an environment's `demo-api.yaml`, merge, then
promote a new version. A full second set of pods starts. `demo-api-preview` reaches the new
version, `demo-api` still serves the old one. `promote` switches all traffic at once.

**5. The tiers.**
```
kubectl -n demo get pods -o wide -L app.kubernetes.io/name     # pod IPs: two different subnet ranges
kubectl get nodes -L tier,topology.kubernetes.io/zone
kubectl -n demo run probe --rm -it --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"busybox:1.36","command":["wget","-qO-","-T","3","http://demo-api/api/info"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```
The probe times out: it is not a frontend pod, so the backend's NetworkPolicy refuses it. The
same request through the frontend (`$URL/api/info`) works.

**6. The database.** Open `$URL` and press "Record a visit": the count is stored in RDS and
survives deleting every pod. In Singapore the count is readable but recording fails, because
that database is a read replica.

**7. Pod autoscaling (HPA).** `while true; do curl -s $URL/api/burn?ms=400 >/dev/null; done`
in a few terminals, then `kubectl -n demo get hpa demo-api -w`: replicas climb.

**8. Node autoscaling.** With the load running, pods go Pending when backend nodes are full.
```
kubectl get nodeclaims -w                  # Sydney: Karpenter launches a node in under a minute
kubectl get nodes -L karpenter.sh/nodepool,tier,node.kubernetes.io/instance-type
```
In Singapore, Cluster Autoscaler raises the backend node group's desired size instead. Stop
the load and watch Karpenter consolidate: it removes the spare node a minute or so later.

**9. A secret from Vault, and rotation.**
```
kubectl -n demo get externalsecret,secret
curl -s $URL/api/info | jq .greeting                          # "hello from vault"
aws secretsmanager get-secret-value --secret-id lab-ap-southeast-2/vault-init \
  --query SecretString --output text | jq -r .root_token      # the token for the next command
kubectl -n vault exec -it vault-0 -- vault login              # paste it
kubectl -n vault exec -it vault-0 -- vault kv patch secret/demo-api/config GREETING="rotated"
```
Within about two minutes the service answers `rotated`, with no restart and no release.

**10. RBAC.**
```
kubectl auth can-i list pods    -n demo --as jane --as-group developers    # yes
kubectl auth can-i get secrets  -n demo --as jane --as-group developers    # no
kubectl auth can-i delete pods  -n demo --as jane --as-group developers    # no
```

**11. Pod security.** `kubectl -n demo run root --image=nginx` is rejected: the namespace
enforces the "restricted" standard.

**12. Self-healing.** `kubectl -n demo delete svc demo-api`. Argo CD puts it back within seconds.
