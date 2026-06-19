import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { SQSClient, ReceiveMessageCommand, DeleteMessageCommand } from "@aws-sdk/client-sqs";
import { DynamoDBClient, UpdateItemCommand } from "@aws-sdk/client-dynamodb";

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

async function streamToString(stream) {
  const chunks = [];
  for await (const c of stream) chunks.push(c);
  return Buffer.concat(chunks).toString("utf-8");
}

async function poll() {
  try {
    const { Messages } = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: QUEUE_URL, MaxNumberOfMessages: 5, WaitTimeSeconds: 2
    }));
    for (const m of Messages || []) {
      const jobId = m.Body;
      console.log(`processing job ${jobId}`);

      // read the payload the api stored in S3
      const obj = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `${jobId}.json` }));
      const payload = await streamToString(obj.Body);
      console.log(`  payload: ${payload}`);

      // mark done in DynamoDB
      await ddb.send(new UpdateItemCommand({
        TableName: TABLE,
        Key: { jobId: { S: jobId } },
        UpdateExpression: "SET #s = :done",
        ExpressionAttributeNames: { "#s": "status" },
        ExpressionAttributeValues: { ":done": { S: "DONE" } }
      }));

      // remove from queue
      await sqs.send(new DeleteMessageCommand({ QueueUrl: QUEUE_URL, ReceiptHandle: m.ReceiptHandle }));
      console.log(`  job ${jobId} -> DONE`);
    }
  } catch (e) {
    console.error("poll error:", e.message);
  }
}

console.log(`worker up, endpoint=${endpoint}, polling SQS...`);
setInterval(poll, 3000);
