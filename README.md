# AWS Job Pipeline (kind + Floci + ArgoCD + Jenkins)

Event-driven pipeline. api stores a job in S3, records state in DynamoDB, enqueues to SQS.
worker consumes SQS, reads S3, updates DynamoDB. All AWS services are emulated by Floci.

## Architecture
    POST /jobs -> api -> S3 (payload) + DynamoDB (SUBMITTED) + SQS (jobId)
                              |
                          worker polls SQS -> reads S3 -> DynamoDB (DONE) -> delete SQS msg

- kind   = runs api + worker pods
- Floci  = provides S3 / SQS / DynamoDB / IAM / ECR on localhost:4566
- Bridge = pods reach Floci via host.docker.internal:4566 (NOT localhost, which is the pod itself)
- ArgoCD = deploys from the gitops repo
- Jenkins= builds, scans, pushes to Floci ECR, bumps tag in gitops repo

## Key learning points (production muscle)
1. Least-privilege IAM: api and worker get DIFFERENT minimal policies (see terraform/main.tf)
2. Event-driven decoupling: api and worker never talk directly, only via SQS
3. CI/CD separation: Jenkins builds artifacts; ArgoCD deploys. Jenkins never touches the cluster.
4. Multi-env: dev/staging/prod from one base via Kustomize overlays + ApplicationSet
5. Pod-to-host networking: host.docker.internal is the bridge from kind to Floci

See SETUP.md for step-by-step.

