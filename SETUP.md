# SETUP - run these in order, one block at a time. Each ends with a CHECK.

Replace the repo URL in argocd/appset.yaml and jenkins/Jenkinsfile with YOUR gitops repo
before you start (it currently says shubhamsinghrathore/gitops-config).

--------------------------------------------------------------------------
## STEP 1 - Start Floci with ECR support
--------------------------------------------------------------------------
docker compose -f floci-compose.yaml up -d

export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

CHECK: aws sts get-caller-identity   # should return an account id, not an error

--------------------------------------------------------------------------
## STEP 2 - Provision AWS resources with Terraform (against Floci)
--------------------------------------------------------------------------
cd terraform
terraform init
terraform apply -auto-approve
cd ..

CHECK: aws s3 ls                       # shows job-uploads
CHECK: aws sqs list-queues             # shows job-queue
CHECK: aws dynamodb list-tables        # shows jobs
CHECK: aws iam list-policies | grep least-privilege   # shows your 2 policies

--------------------------------------------------------------------------
## STEP 3 - Make sure kind cluster can reach the host (one-time)
--------------------------------------------------------------------------
# On Docker Desktop (your Mac) host.docker.internal already resolves from kind nodes.
# Verify your kind cluster exists:
kubectl config use-context kind-capstone   # or whatever your cluster is named
kubectl get nodes

CHECK: nodes show Ready

--------------------------------------------------------------------------
## STEP 4 - Build images and push to Floci's ECR (manual first run)
--------------------------------------------------------------------------
# Floci serves an ECR-shaped registry. Create repos, then push.
aws ecr create-repository --repository-name api    || true
aws ecr create-repository --repository-name worker || true

docker build -t localhost:4566/api:1    ./services/api
docker build -t localhost:4566/worker:1 ./services/worker
docker push localhost:4566/api:1
docker push localhost:4566/worker:1

CHECK: aws ecr list-images --repository-name api   # shows tag 1

--------------------------------------------------------------------------
## STEP 5 - Point the base manifests at the pushed images
--------------------------------------------------------------------------
# kind pulls images via host.docker.internal:4566 (the host registry).
sed -i '' 's|REGISTRY/api:latest|host.docker.internal:4566/api:1|'       gitops/base/api-deployment.yaml
sed -i '' 's|REGISTRY/worker:latest|host.docker.internal:4566/worker:1|' gitops/base/worker-deployment.yaml

CHECK: grep image gitops/base/*.yaml   # both point at host.docker.internal:4566

--------------------------------------------------------------------------
## STEP 6 - Push everything to your gitops repo
--------------------------------------------------------------------------
# Put the gitops/ folder into your gitops-config repo (the one ArgoCD watches).
git add . && git commit -m "aws job pipeline" && git push origin main

--------------------------------------------------------------------------
## STEP 7 - Deploy via ArgoCD ApplicationSet
--------------------------------------------------------------------------
kubectl apply -f argocd/appset.yaml

CHECK: ArgoCD UI shows aws-pipeline-dev / -staging / -prod, all Synced + Healthy
CHECK: kubectl get pods -n pipeline-dev    # api + worker Running

--------------------------------------------------------------------------
## STEP 8 - PROVE IT END TO END (the payoff)
--------------------------------------------------------------------------
kubectl port-forward -n pipeline-dev svc/api 3000:3000 &
curl -X POST localhost:3000/jobs -H 'content-type: application/json' -d '{"task":"resize-image"}'
# -> {"jobId":"...","status":"SUBMITTED"}

# watch the worker pick it up:
kubectl logs -n pipeline-dev deploy/worker -f
# -> processing job ... / payload ... / job ... -> DONE

# confirm the full AWS round-trip:
aws s3 ls s3://job-uploads/                 # the payload file exists
aws dynamodb scan --table-name jobs         # status flipped SUBMITTED -> DONE

CHECK: DynamoDB shows the job as DONE. That means api->S3->SQS->worker->DynamoDB all worked.

--------------------------------------------------------------------------
## STEP 9 (later) - Full CI loop with Jenkins
--------------------------------------------------------------------------
# Point Jenkins at this repo with jenkins/Jenkinsfile.
# A build then does: build -> trivy scan -> push to Floci ECR -> bump tag in gitops repo -> ArgoCD deploys.
# This closes the loop your interviews centered on.
