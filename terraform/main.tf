# Terraform pointed at Floci (local AWS emulator on :4566)
# Provisions: S3 bucket, SQS queue, DynamoDB table, and two least-privilege IAM policies.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true


  endpoints {
    s3       = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    iam      = "http://localhost:4566"
    sts      = "http://localhost:4566"
  }
}

# --- S3: where uploaded job files live ---
resource "aws_s3_bucket" "jobs" {
  bucket = "job-uploads"
}

# --- SQS: the job queue connecting api -> worker ---
resource "aws_sqs_queue" "jobs" {
  name = "job-queue"
}

# --- DynamoDB: job state/status table ---
resource "aws_dynamodb_table" "jobs" {
  name         = "jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "jobId"

  attribute {
    name = "jobId"
    type = "S"
  }
}

# --- IAM: LEAST-PRIVILEGE policy for the API service ---
# api only needs: write to S3, send to SQS, write job record to DynamoDB
resource "aws_iam_policy" "api_policy" {
  name = "api-least-privilege"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ApiS3Write"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.jobs.arn}/*"
      },
      {
        Sid      = "ApiSqsSend"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid      = "ApiDdbWrite"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.jobs.arn
      }
    ]
  })
}

# --- IAM: LEAST-PRIVILEGE policy for the WORKER service ---
# worker only needs: receive/delete from SQS, read from S3, update DynamoDB
resource "aws_iam_policy" "worker_policy" {
  name = "worker-least-privilege"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WorkerSqsConsume"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid      = "WorkerS3Read"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.jobs.arn}/*"
      },
      {
        Sid      = "WorkerDdbUpdate"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.jobs.arn
      }
    ]
  })
}


# Alerting stack: when a service-issue event fires, route it through EventBridge -> SNS -> subscriber.
# Flow: event source -> aws_cloudwatch_event_rule (filter) -> aws_cloudwatch_event_target (route) -> aws_sns_topic (broadcast) -> aws_sns_topic_subscription (deliver)

# SNS topic: the broadcaster. Every subscriber to this topic gets the alert.
resource "aws_sns_topic" "alerts" {
  name = "service-alerts"
}

# Subscription: the destination the alert is delivered to.
# Locally this is a throwaway HTTP listener (python http.server on :9000) standing in for Slack/email.
# Note: HTTP subs normally need a confirmation handshake before delivery starts.
resource "aws_sns_topic_subscription" "alert_sub" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "http"
  endpoint  = "http://host.docker.internal:9000"
}

# EventBridge rule: the FILTER. Only events matching this pattern (AWS Health service issues) are caught.
resource "aws_cloudwatch_event_rule" "health" {
  name = "service-health-issues"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
  })
}

# EventBridge target: the DESTINATION. Sends every event the rule catches to the SNS topic above.
resource "aws_cloudwatch_event_target" "to_sns" {
  rule      = aws_cloudwatch_event_rule.health.name
  target_id = "send-to-sns"
  arn       = aws_sns_topic.alerts.arn
}

output "bucket"     { value = aws_s3_bucket.jobs.bucket }
output "queue_url"  { value = aws_sqs_queue.jobs.url }
output "table"      { value = aws_dynamodb_table.jobs.name }
