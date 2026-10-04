# AWS Resources Used

This folder documents every AWS resource in the Event Announcement project. There is one file per service, and each covers what the service is, why the project needs it, how it's configured and how to inspect it.

![Architecture diagram](architecture.png)

## Resources at a glance

| # | Service | Role in the project | What gets created | Details |
|---|---|---|---|---|
| 1 | **Amazon S3** | Hosts the website and stores the event data | 1 bucket with static website hosting, a bucket policy, and 4 objects | [01-amazon-s3.md](01-amazon-s3.md) |
| 2 | **Amazon API Gateway** | Public HTTPS endpoints the browser calls | 1 HTTP API, 2 routes, 2 integrations, 1 stage | [02-amazon-api-gateway.md](02-amazon-api-gateway.md) |
| 3 | **AWS Lambda** | Backend logic that runs on demand | 2 functions: subscribe and create-event | [03-aws-lambda.md](03-aws-lambda.md) |
| 4 | **Amazon SNS** | Email subscriptions and notifications | 1 topic plus one subscription per subscriber | [04-amazon-sns.md](04-amazon-sns.md) |
| 5 | **AWS IAM** | Controls which component may do what | 2 roles, 2 inline policies, Lambda invoke permissions, plus the bucket policy | [05-aws-iam.md](05-aws-iam.md) |
| 6 | **Amazon CloudWatch Logs** | Records what each Lambda did, for debugging | 2 log groups (created automatically) | [06-amazon-cloudwatch-logs.md](06-amazon-cloudwatch-logs.md) |

**Interview prep:** [07-interview-qna.md](07-interview-qna.md) has 50 likely interview questions about this project, with answers, plus quick-fire facts.

## How they work together

**Viewing events:**

1. The browser loads `index.html` and `styles.css` from the **S3** website endpoint.
2. The page fetches `events.json` from the same bucket and shows the events.

**Subscribing:**

1. The browser sends `POST /subscribe` to **API Gateway**.
2. API Gateway invokes the **subscribe Lambda**. **IAM** permits this through the Lambda's resource policy.
3. The Lambda calls `sns:Subscribe`, which its **IAM role** allows.
4. **SNS** emails a confirmation link to the address.

**Creating an event:**

1. The browser sends `POST /create-event` to **API Gateway**, which invokes the **create-event Lambda**.
2. The Lambda reads `events.json` from **S3**, appends the event and writes the file back.
3. The Lambda calls `sns:Publish`, and **SNS** emails every confirmed subscriber.
4. Every step is logged to **CloudWatch Logs**.

## Naming convention

`scripts/deploy.sh` names every resource after the `PROJECT` variable (default `event-announcement`):

| Resource | Name |
|---|---|
| S3 bucket | `event-announcement-site-<account-id>-<region>` |
| SNS topic | `event-announcement-notifications` |
| Lambda functions | `event-announcement-subscribe`, `event-announcement-create-event` |
| IAM roles | `event-announcement-subscribe-lambda-role`, `event-announcement-create-event-lambda-role` |
| HTTP API | `event-announcement-api` |
| Log groups | `/aws/lambda/event-announcement-subscribe`, `/aws/lambda/event-announcement-create-event` |

The account ID and region in the bucket name make it globally unique. S3 bucket names are shared across all AWS accounts.
