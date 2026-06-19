import express from "express";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { randomUUID } from "crypto";

// AWS_ENDPOINT comes from env. localhost on host, host.docker.internal inside kind pods.
const endpoint = process.env.AWS_ENDPOINT || "http://localhost:4566";
const region = "us-east-1";
const creds = { accessKeyId: "test", secretAccessKey: "test" };
const common = { region, endpoint, credentials: creds };

const s3 = new S3Client({ ...common, forcePathStyle: true });
const sqs = new SQSClient(common);
const ddb = new DynamoDBClient(common);

const BUCKET = "job-uploads";
const QUEUE_URL = `${endpoint}/000000000000/job-queue`;
const TABLE = "jobs";

const app = express();
app.use(express.json());

app.get("/healthz", (_req, res) => res.send("ok"));

// Submit a job: store payload in S3, write state to DynamoDB, enqueue to SQS
app.post("/jobs", async (req, res) => {
  try {
    const jobId = randomUUID();
    const payload = JSON.stringify(req.body || { note: "empty" });

    await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: `${jobId}.json`, Body: payload }));
    await ddb.send(new PutItemCommand({
      TableName: TABLE,
      Item: { jobId: { S: jobId }, status: { S: "SUBMITTED" } }
    }));
    await sqs.send(new SendMessageCommand({ QueueUrl: QUEUE_URL, MessageBody: jobId }));

    res.status(201).json({ jobId, status: "SUBMITTED" });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

app.listen(3000, () => console.log(`api up on :3000, endpoint=${endpoint}`));
