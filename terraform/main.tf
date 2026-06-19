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

output "bucket"     { value = aws_s3_bucket.jobs.bucket }
output "queue_url"  { value = aws_sqs_queue.jobs.url }
output "table"      { value = aws_dynamodb_table.jobs.name }
