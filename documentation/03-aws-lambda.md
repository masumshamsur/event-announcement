# AWS Lambda

## What it is

Lambda runs your code without servers. You upload a function, and AWS runs it only when something triggers it, such as an API request. You pay per request and per millisecond of run time, so when nobody uses the site, it costs nothing.

## Why this project needs it

Two actions need logic that a static website can't perform safely in the browser:

- **Subscribing** needs a call to SNS. That requires AWS credentials, which must never be shipped to a browser.
- **Creating an event** needs input validation, a safe update of `events.json` in S3, and a notification to all subscribers.

Lambda runs that code on the server side with its own IAM role. The browser never sees any credentials, and nothing runs (or costs money) between requests.

## What was created

### 1. Subscription Lambda: `event-announcement-subscribe`

| Item | Value |
|---|---|
| Source | [lambdas/subscribe/lambda_function.py](../lambdas/subscribe/lambda_function.py) |
| Trigger | API Gateway `POST /subscribe` |
| Role | `event-announcement-subscribe-lambda-role` |
| Env vars | `SNS_TOPIC_ARN` |

The function runs these steps:
1. Parse the JSON body.
2. Validate the email: it must match a basic pattern and be 254 characters or fewer. It's then trimmed and lowercased.
3. Call `sns.subscribe(Protocol="email", Endpoint=email)`.
4. Return `200` with a message telling the person to check their inbox, or `400` or `500` on failure.

### 2. Event Registration Lambda: `event-announcement-create-event`

| Item | Value |
|---|---|
| Source | [lambdas/create_event/lambda_function.py](../lambdas/create_event/lambda_function.py) |
| Trigger | API Gateway `POST /create-event` |
| Role | `event-announcement-create-event-lambda-role` |
| Env vars | `SNS_TOPIC_ARN`, `BUCKET_NAME`, `EVENTS_KEY=events.json` |

The function runs these steps:
1. Parse the JSON body and validate it. `title` (max 120 characters), `date` (`YYYY-MM-DD`) and `description` (max 1000 characters) are all required.
2. Add an `id` (a UUID) and a `createdAt` timestamp in UTC.
3. Read `events.json` from S3, append the new event, and write it back with a **conditional write** (`If-Match` ETag). On a conflict it retries, up to 5 times. See [01-amazon-s3.md](01-amazon-s3.md).
4. Call `sns.publish(...)` with the event details. If publishing fails, the event is still saved, and the response says that notifications failed.
5. Return `200` with the saved event, or `400` or `500`.

## Configuration and why

| Setting | Value | Why |
|---|---|---|
| Runtime | `python3.13` | Current Python runtime, and `boto3` (the AWS SDK) is built in, so there are no dependencies to package |
| Handler | `lambda_function.lambda_handler` | The file and function name Lambda calls |
| Memory | 128 MB | The smallest size. These functions only do a few API calls, so more memory would only cost more. |
| Timeout | 15 s | Leaves room for S3 retries and SNS calls. The default 3 s could be too short on a cold start plus retries. |
| Environment variables | Topic ARN, bucket name, file key | The code holds no account-specific values, so the same code works in any account or region |
| Packaging | One `.py` file zipped (in `.build/`) | No third-party libraries are needed |

### Design notes

- **One function per route:** each function gets its own minimal IAM role. The subscribe function can't touch S3, for example. Each also has its own logs and metrics.
- **CORS headers in responses:** both functions return `Access-Control-Allow-Origin` and handle `OPTIONS`. This is a fallback: with the HTTP API's CORS config, API Gateway already handles preflights.
- **Server-side validation:** the browser also validates input, but anyone can call the API directly with `curl`, so the Lambda is the real gatekeeper.

## How it connects to other resources

| Direction | Resource | Permission source |
|---|---|---|
| API Gateway → Lambda | Invokes the function | Resource-based policy on the function ([05-aws-iam.md](05-aws-iam.md)) |
| Lambda → SNS | `Subscribe` / `Publish` | The function's IAM role |
| Lambda → S3 | `GetObject` / `PutObject` on `events.json` | The create-event role |
| Lambda → CloudWatch Logs | Writes logs | `AWSLambdaBasicExecutionRole` |

## Alternatives considered

| Option | Why it wasn't used |
|---|---|
| One Lambda handling both routes | Fewer resources, but one role would then need both S3 and SNS access, which breaks least privilege. Separate functions are also easier to debug. |
| EC2 or ECS running an API server | Runs and costs money all the time, and needs patching and scaling. That's far more than two small endpoints need. |
| Node.js runtime | Would work just as well. Python was chosen for readability and its built-in `boto3`. |

## Cost

The Free Tier includes **1 million requests and 400,000 GB-seconds per month**. At 128 MB and well under a second per call, lab usage costs $0.

## Inspect it

**CLI:**
```bash
aws lambda get-function-configuration --function-name event-announcement-create-event
aws logs tail /aws/lambda/event-announcement-create-event --follow   # live logs

# Invoke directly, bypassing API Gateway
aws lambda invoke --function-name event-announcement-subscribe \
  --cli-binary-format raw-in-base64-out \
  --payload '{"body":"{\"email\":\"bad\"}"}' /dev/stdout
```

**Console:** go to **Lambda**, then **Functions**, then the function name.
- **Code** shows the source.
- **Configuration → Environment variables** shows the env vars.
- **Configuration → Permissions** shows the role and resource-based policy.
- **Monitor** shows the metrics and links to the logs.

**Tests:** `python3 tests/test_lambdas.py` runs both handlers against fake S3 and SNS. See [Testing](../README.md#testing).

## Cleanup

`scripts/teardown.sh` deletes both functions and their log groups.
