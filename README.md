# Movie Picture Pipeline

GitHub Actions CI/CD for the Movie Picture catalog: a React frontend (`starter/frontend`) that lists movies served by a Flask API (`starter/backend`), both deployed to Amazon EKS.

| | |
| --- | --- |
| Frontend | http://a323708f25bdb48229fb5fc4c5274b1c-703806197.us-east-1.elb.amazonaws.com/ |
| Backend API | http://aae687abe0e8242a79109e10651b1dca-1855059415.us-east-1.elb.amazonaws.com/movies |
| Actions | https://github.com/Daniel-Adekunle-Accenture/movie-picture-pipeline/actions |

The two URLs are AWS load balancers in a temporary Udacity lab account. They stop working once the lab is torn down; the screenshots below show both apps running.

## Workflows

All four live in `.github/workflows/`. Each one runs `lint` and `test` as separate jobs in parallel; the Docker build job has `needs: [lint, test]`, and in CD the deploy job has `needs: build`. A failed lint or test therefore skips the build, and a failed build skips the deploy. Nothing uses `continue-on-error`.

| File | Name | Runs automatically on | Jobs |
| --- | --- | --- | --- |
| `frontend-ci.yaml` | Frontend Continuous Integration | pull request to `main` that changes `starter/frontend/**` or this file | lint, test → build |
| `backend-ci.yaml` | Backend Continuous Integration | pull request to `main` that changes `starter/backend/**` or this file | lint, test → build |
| `frontend-cd.yaml` | Frontend Continuous Deployment | push to `main` that changes `starter/frontend/**` or this file | lint, test → build (push to ECR) → deploy |
| `backend-cd.yaml` | Backend Continuous Deployment | push to `main` that changes `starter/backend/**` or this file | lint, test → build (push to ECR) → deploy |

All four also have `workflow_dispatch` for manual runs. CD's build and deploy jobs only run when `github.ref` is `refs/heads/main`, so a manual run from another branch can lint and test but never pushes or deploys.

**CI** uses `permissions: contents: read` and no AWS credentials.
- Frontend: Node from `starter/frontend/.nvmrc` (18.14) via `actions/setup-node` with the npm cache keyed on `starter/frontend/package-lock.json`, then `npm ci`, `npm run lint`, `npm test` (with `CI=true`), and `docker build --build-arg REACT_APP_MOVIE_API_URL=http://localhost:5000`.
- Backend: Python 3.10 (from the Pipfile) via `actions/setup-python` with the pipenv cache, then `pipenv install --dev --deploy`, `pipenv run lint` (flake8), `pipenv run test` (pytest), and `docker build`.

**CD** repeats lint and test, then:
1. **build**: configures AWS credentials from GitHub Secrets (`aws-actions/configure-aws-credentials`), logs in with `aws-actions/amazon-ecr-login`, builds the image tagged with the commit SHA (`<registry>/<app>:${{ github.sha }}`) and pushes it to ECR. The full image reference is passed to the deploy job as a job output, so deploy uses exactly the image that was built.
2. **deploy**: installs kubectl 1.35 (matching the cluster), runs `aws eks update-kubeconfig --name cluster`, then in `starter/<app>/k8s` runs `kustomize edit set image <app>=<image>` and `kustomize build | kubectl apply -f -`. The image edit only touches the runner's checkout and is never committed. It then waits for `kubectl rollout status`, checks that the Deployment and its running pods use this run's SHA tag, and runs a smoke test through the load balancer: the backend must return a non-empty movie list from `/movies`, and the frontend must serve the page with the backend URL compiled into its JavaScript bundle. Each deploy job has a concurrency group (`backend-deploy` / `frontend-deploy`), so rollouts of the same app never overlap.

## Variables and secrets

| Name | Kind | Used by | Value |
| --- | --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | repository secret | both CD workflows | access key of IAM user `github-action-user` |
| `AWS_SECRET_ACCESS_KEY` | repository secret | both CD workflows | its secret key |
| `REACT_APP_MOVIE_API_URL` | repository variable | `frontend-cd.yaml` | backend base URL, e.g. `http://<backend load balancer>` (no trailing slash; the Service listens on port 80) |

CI sets `REACT_APP_MOVIE_API_URL=http://localhost:5000` as a workflow `env` value. Region (`us-east-1`), cluster name (`cluster`), ECR repository names (`frontend`, `backend`), and the kubectl, Python and pipenv versions are `env` values at the top of each workflow. No credentials appear in YAML, Git or logs.

`github-action-user` can only do what CD needs: `ecr:GetAuthorizationToken`, push/pull on the two project repositories, and `eks:DescribeCluster` on the project cluster. Inside Kubernetes it has `AmazonEKSEditPolicy` scoped to the `default` namespace through an EKS access entry, not cluster admin.

## Infrastructure (`setup/`)

Terraform in `setup/terraform` creates the VPC and subnets, the two private ECR repositories (`frontend`, `backend`), an EKS 1.35 cluster named `cluster` with one `t3.small` AL2023 node (node role has `AmazonEC2ContainerRegistryReadOnly` for image pulls), and the scoped `github-action-user`. Changes from the supplied Terraform:

- The Udacity lab role is denied `iam:CreateOpenIDConnectProvider`, so GitHub OIDC federation was not possible. CD uses an access key for `github-action-user`, scoped as above, instead of the supplied `ecr:*`/`eks:*`/`ec2:*` policy and cluster-admin access entry. `setup/init.sh` (which maps the user to `system:masters`) is kept for reference but not used.
- State lives in a private, versioned, encrypted S3 bucket in the lab account, so teardown still works after a workspace reset. `setup/bootstrap-state.sh` creates or finds the bucket and writes the git-ignored `backend.hcl`.
- Resources carry the tag `Project=movie-picture-pipeline`. The exceptions are the IAM user and its policy, which use an untagged provider alias because the lab denies `iam:TagUser`.

```bash
cd setup
./bootstrap-state.sh
cd terraform
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

Then in the AWS console, IAM → Users → `github-action-user` → Security credentials → Create access key ("Application running outside AWS"), and store the two values as the repository secrets above.

## Deployment order

1. Merge CI first and prove it on pull requests (no AWS needed).
2. Provision with Terraform and add the two secrets.
3. Backend first: a push to `main` that touches `starter/backend` (or a manual run of Backend Continuous Deployment) builds, pushes and deploys the API. Its job summary prints the load balancer URL.
4. Set the repository variable `REACT_APP_MOVIE_API_URL` to that base URL.
5. Frontend next: a push to `main` that touches `starter/frontend` (or a manual run) builds the app against that URL and deploys it.

The frontend calls the backend from the browser, and Flask-CORS allows any origin. Both Services are plain HTTP on port 80, so there is no mixed content.

## Verification

- Each CD run's summary lists the pushed image (tag and digest), the URL, and the smoke-test result.
- `curl http://<backend>/movies` returns the three starter movies.
- Opening `http://<frontend>/` in a browser shows the Movie List from the backend; clicking a title loads its details.
- `kubectl get deploy,pods,svc -o wide` shows both Deployments on commit-SHA images.

### Evidence

Screenshots are in `screenshots/`:

| File | Shows |
| --- | --- |
| `01-frontend-ci-pull-request.png` | Frontend CI on PR #1: lint and test in parallel, then the Docker build |
| `02-backend-ci-pull-request.png` | Backend CI on PR #1, same shape |
| `03-pr1-all-ci-checks-passed.png` | PR #1 with all six CI checks passing before merge |
| `04-ci-failing-test-blocks-build.png` | Demo PR #4 (closed, not merged): Test fails, Build Docker image is skipped, run fails |
| `05-path-filter-backend-only-checks.png` | PR #4 checks: a backend-only change ran only Backend CI |
| `06-backend-cd-push-to-main.png` | Backend CD triggered by the push to `main`: lint, test → build → deploy |
| `07-backend-cd-summary-image-and-url.png` | Backend CD summary: SHA-tagged ECR image, digest, load balancer URL, movie titles |
| `08-frontend-cd-push-to-main.png` | Frontend CD triggered by the push to `main` |
| `09-frontend-cd-summary-image-and-url.png` | Frontend CD summary: SHA-tagged image, frontend URL, backend URL compiled into the bundle |
| `10-manual-workflow-dispatch-runs.png` | All four workflows run manually (`workflow_dispatch`) on `main`, all passing |
| `11-ecr-backend-sha-tagged-images.png` | Backend images in the private ECR repository, tagged with commit SHAs |
| `12-ecr-frontend-sha-tagged-images.png` | Frontend images in the private ECR repository, tagged with commit SHAs |
| `13-eks-deployments-ready.png` | EKS console: `backend` and `frontend` Deployments 1/1 available |
| `14-eks-services.png` | EKS console: the `backend` and `frontend` Services |
| `15-deploy-job-running-pod-sha-image.png` | The deploy job's `kubectl get pods` check: the running pod uses this run's commit-SHA image |
| `16-backend-movies-api.png` | `GET /movies` on the backend load balancer |
| `17-frontend-movie-list.png` | The frontend on its load balancer, rendering the list from the backend (details for "A Quiet Place" loaded via `/movies/789`) |

Screenshots 16 and 17 were taken in a browser whose address bar is not part of the capture, so the URL is printed in a caption strip above the page. Some ECR images are tagged with commit SHAs from an earlier copy of this repository, because an earlier copy of this repository pushed to the same ECR repositories. In the AWS console screenshots, the account and session box is blacked out.

### Lab session note

The manual CD runs first failed at ECR login with an "explicit deny in a service control policy", because the Udacity lab session had ended. The lab also stopped the EKS worker, and its auto-scaled replacement could not join the cluster while the session was inactive. After the session was restarted, that stuck instance was terminated, as the lesson's troubleshooting describes. The node group launched a new worker, and re-running the same runs (attempt 2) passed.

## Local development

From the team notes in `starter/frontend/frontend-development-notes.md` and the starter README:

```bash
# Backend (Python 3.10, pipenv)
cd starter/backend && pipenv install --dev && pipenv run lint && pipenv run test
docker build --tag mp-backend . && docker run -p 5000:5000 mp-backend   # curl http://localhost:5000/movies

# Frontend (Node 18.14 from .nvmrc)
cd starter/frontend && npm ci && npm run lint && CI=true npm test
docker build --build-arg REACT_APP_MOVIE_API_URL=http://localhost:5000 --tag mp-frontend .
docker run -p 3000:3000 mp-frontend
```

Two runner-specific fixes live in the workflows rather than the starter code:
- `CFLAGS=-std=gnu17` for the backend jobs: uWSGI 2.0.21 does not compile under the C23 default of the runner's GCC. It's the same fix the starter Dockerfile already uses.
- The Docker build jobs first try to pull the Dockerfile's `public.ecr.aws/docker/library/...` base image. If ECR Public rate-limits the shared runner IP (HTTP 429), they pull the identical Docker Hub official image and tag it with the Dockerfile's name.

## Teardown

`setup/teardown.sh` removes everything in the order AWS needs:

1. `kubectl delete service frontend backend`, then wait until their load balancers are gone (they would otherwise block VPC deletion).
2. `terraform destroy` with the same S3 backend.
3. Delete the state bucket, including all object versions.
4. List any leftovers: clusters, ECR repositories, tagged VPCs, load balancers, unattached volumes, project IAM roles/users/policies, and state buckets.

Afterwards, remove the two repository secrets and the variable in GitHub.
