# Interview Questions & Answers

These are questions an interviewer is likely to ask about this project, with answers based on what was actually built. Each answer is written to be said out loud in about 30–90 seconds. Start with the short version, and go deeper only if they ask a follow-up.

**Contents**
1. [Project overview](#1-project-overview)
2. [Architecture and design decisions](#2-architecture-and-design-decisions)
3. [Amazon S3](#3-amazon-s3)
4. [API Gateway](#4-api-gateway)
5. [AWS Lambda](#5-aws-lambda)
6. [Amazon SNS](#6-amazon-sns)
7. [IAM and security](#7-iam-and-security)
8. [Concurrency and data consistency](#8-concurrency-and-data-consistency)
9. [Monitoring and troubleshooting](#9-monitoring-and-troubleshooting)
10. [Deployment, testing and CI/CD](#10-deployment-testing-and-cicd)
11. [Cost](#11-cost)
12. [Scaling and production readiness](#12-scaling-and-production-readiness)
13. [Behavioral questions](#13-behavioral-questions)

---

## 1. Project overview

### Q1. Walk me through this project.

**Answer:** It's a serverless website for announcing events. Visitors can view upcoming events, create new ones through a form, and subscribe by email to get notified when an event is posted.

- **Frontend:** plain HTML, CSS and JavaScript hosted on S3 static website hosting. The event list is a JSON file, `events.json`, in the same bucket.
- **API:** two endpoints on API Gateway: `POST /subscribe` and `POST /create-event`.
- **Subscribe:** a Lambda adds the email to an SNS topic, and SNS sends a confirmation link.
- **Create event:** another Lambda validates the input, appends the event to `events.json` with an S3 conditional write so concurrent submissions don't overwrite each other, and publishes to SNS, which emails every confirmed subscriber.

Each Lambda has its own least-privilege IAM role. I deployed it with an idempotent AWS CLI script, and the Lambdas have unit tests.

### Q2. Why serverless for this?

**Answer:** The workload is small and bursty: most of the time nobody is using it. With serverless I pay only per request, there are no servers to patch, and it scales automatically. An EC2-based version would cost money 24/7 and need OS patching, scaling and a web server just to serve a few static files and two endpoints.

### Q3. What was the hardest part?

**Answer:** Updating `events.json` safely. The Lambda reads the file, appends an event and writes it back. If two people submit at the same moment, both read the same version and the second write silently erases the first event.

I fixed it with S3 conditional writes. The Lambda remembers the file's ETag when it reads, writes with `If-Match: <ETag>`, and if S3 returns `412 Precondition Failed` it re-reads and retries. I wrote a unit test that simulates the conflict to prove both events survive.

---

## 2. Architecture and design decisions

### Q4. Why store events in a JSON file instead of a database?

**Answer:** For this scale it keeps the site fully static. The browser loads the event list with one plain GET from S3, with no "list events" API, no extra Lambda and no database. The trade-offs are that every write rewrites the whole file, there's no querying, and concurrent writes need extra handling, which I solved with conditional writes.

For production I'd move to **DynamoDB**: one item per event, a `GET /events` endpoint, and queries such as upcoming events only.

### Q5. Why two Lambda functions instead of one?

**Answer:** Mainly **least privilege**. The subscribe function only needs `sns:Subscribe`. The create-event function needs S3 read and write plus `sns:Publish`. With one function, a single role would hold all of those permissions, so a bug in the subscribe path could write to S3.

Separate functions also give each one its own logs, metrics and deploys.

### Q6. Why does the browser go through API Gateway and Lambda instead of calling S3 or SNS directly?

**Answer:** Calling S3 or SNS directly would mean giving the browser AWS credentials with write access, and anyone could pull those out of the page. Going through Lambda keeps the credentials on the server (the Lambda's role). It also lets me validate input before anything is written. The browser can only *read* S3, through the bucket policy.

### Q7. What happens, step by step, when a user clicks "Submit Event"?

**Answer:**
1. JavaScript does basic validation, then sends `POST /create-event` with a JSON body.
2. The browser sends a CORS preflight (`OPTIONS`) first, because the API is on a different domain. API Gateway answers it.
3. API Gateway invokes the create-event Lambda. That's allowed by the Lambda's resource-based policy, scoped to this API and route.
4. The Lambda validates the fields, adds an `id` and `createdAt`, reads `events.json` along with its ETag, appends the event, and does a conditional `PutObject`.
5. It calls `sns:Publish`, and SNS emails every confirmed subscriber.
6. The Lambda returns 200, and the page re-fetches `events.json` with a cache-buster so the new event shows immediately.

### Q8. What would you change in the architecture if you built it again?

**Answer:**
- **Hosting:** put CloudFront in front of a private S3 bucket (Origin Access Control) for HTTPS and caching.
- **Data:** use DynamoDB instead of the JSON file.
- **Access control:** add a Cognito authorizer so only signed-in organizers can create events.
- **Infrastructure:** write it with Terraform or AWS SAM instead of a CLI script.

The core flow (API Gateway → Lambda → SNS) I'd keep.

---

## 3. Amazon S3

### Q9. How does S3 static website hosting work, and what did you have to configure?

**Answer:** You enable website hosting on the bucket and set an index document. S3 then gives the bucket a website endpoint that serves files over HTTP. I configured three things:
1. **Website hosting**, with `index.html` as the index document.
2. **Block Public Access:** I turned off only the two *policy* settings, so a public bucket policy is allowed. Public ACLs stay blocked.
3. **A bucket policy** allowing `s3:GetObject` for `Principal: *`.

### Q10. Your bucket is public. Isn't that a security risk?

**Answer:** It's public **read-only**, which is what a public website needs. The bucket policy allows only `s3:GetObject`: no `ListBucket`, so nobody can list the files, and no `PutObject` or `DeleteObject`. Public ACLs are still blocked, so no object can be made writable through an ACL. The only thing that can write is the create-event Lambda's role, and only to `events.json`.

In production I'd keep the bucket fully private behind CloudFront with Origin Access Control.

### Q11. Why did you set `Cache-Control: no-cache` on `events.json`?

**Answer:** Without it, the browser might show a cached, outdated event list after someone creates an event. `no-cache, no-store, must-revalidate` tells browsers to always fetch a fresh copy. The page also adds `?t=<timestamp>` to the request as a belt-and-braces cache-buster.

### Q12. Is S3 strongly consistent? Does that matter here?

**Answer:** Yes. Since December 2020, S3 gives strong read-after-write consistency, so a GET right after a successful PUT returns the new data. That's why the page can re-fetch `events.json` right after the API returns and see the new event.

Consistency doesn't prevent **lost updates** from two concurrent writers, though. That's a separate problem, which I handled with conditional writes.

---

## 4. API Gateway

### Q13. HTTP API or REST API — which did you use and why?

**Answer:** An **HTTP API**. It's cheaper per request, has lower latency, has built-in CORS configuration and needs less setup for Lambda proxy routes. REST APIs add API keys and usage plans, request validation, response caching and direct AWS WAF integration. I didn't need any of those for two simple endpoints.

If I needed API keys, per-client quotas or WAF attached directly to the API, I'd pick a REST API.

### Q14. What is CORS and why did you need it?

**Answer:** CORS is a browser security rule. A page can only call an API on a different origin (scheme, domain or port) if that API explicitly allows it. My site is on the `s3-website...amazonaws.com` domain and the API on `execute-api...amazonaws.com`, which are different origins.

For a JSON `POST`, the browser first sends an `OPTIONS` preflight. I configured CORS on the HTTP API (allow origin `*`, methods `POST, OPTIONS`, header `content-type`), so API Gateway answers the preflight and the browser then sends the real request. In production I'd restrict the allowed origin to my own domain.

### Q15. What is a Lambda proxy integration?

**Answer:** API Gateway passes the whole HTTP request to Lambda as an event: method, path, headers and body. The Lambda returns a status code, headers and body, which API Gateway sends back unchanged. All the logic lives in the Lambda, and API Gateway does no mapping. I used `AWS_PROXY` with payload format 2.0.

### Q16. How does API Gateway get permission to invoke your Lambda?

**Answer:** Through a **resource-based policy on the Lambda function**, added with `aws lambda add-permission`. It allows the principal `apigateway.amazonaws.com` to call `lambda:InvokeFunction`. I scoped the `SourceArn` to my API ID and the specific route, for example `.../<api-id>/*/*/subscribe`, so no other API can invoke the function.

---

## 5. AWS Lambda

### Q17. How does your Lambda know which bucket and topic to use?

**Answer:** Through **environment variables**: `BUCKET_NAME`, `SNS_TOPIC_ARN` and `EVENTS_KEY`, which the deploy script sets. The code contains no account-specific values, so the same code deploys to any account or region.

### Q18. Why 128 MB memory and a 15-second timeout?

**Answer:** The functions only make a couple of AWS API calls, so 128 MB, the minimum, is enough, and more memory would only cost more. The default timeout is 3 seconds, which could be too tight with a cold start plus S3 retries on a write conflict, so I raised it to 15 seconds.

### Q19. What is a cold start? Does it matter here?

**Answer:** When no warm instance of a function exists, Lambda has to create a new execution environment, start the runtime and load the code before handling the request. That adds latency, typically a few hundred milliseconds for a small Python function.

It barely matters here: a slight delay on submitting a form is acceptable. If it did matter, I could use provisioned concurrency, or keep packages small and create clients outside the handler. I already do the latter: the `boto3` clients are created at module level, so warm invocations reuse them.

### Q20. Why do you validate on the server if the browser already validates the form?

**Answer:** Browser validation is for user experience only. Anyone can skip it by calling the API with `curl` or Postman. The Lambda is the real gatekeeper: required fields, length limits, ISO date format and a JSON object body. Bad input gets a `400` with a clear message and never reaches S3 or SNS.

### Q21. What happens if SNS publishing fails after the event was saved?

**Answer:** The event is saved, so the Lambda still returns 200, with the message "event published, but subscribers could not be notified", and logs the error. I chose that over returning an error, because an error would make the user resubmit and create a duplicate event.

In production I'd make notification asynchronous and retryable: an S3 or DynamoDB stream event, or an SQS queue with a dead-letter queue.

---

## 6. Amazon SNS

### Q22. Why SNS for emails instead of SES?

**Answer:** SNS manages the subscriber list, the double opt-in confirmation and unsubscribe links for me. One `Publish` call reaches every subscriber. With SES I'd need to store the email list myself, loop over it, verify a sending domain and build the unsubscribe handling.

SNS's drawbacks are plain-text emails and a generic AWS sender address. For branded HTML emails I'd switch to SES.

### Q23. What happens after someone subscribes?

**Answer:** The subscription is created in **Pending confirmation** state, and SNS emails a confirmation link. Nothing is delivered until they click it and the subscription becomes **Confirmed**. An unconfirmed subscription expires after 3 days. This double opt-in stops people from being subscribed without their consent.

### Q24. How would you let users subscribe only to certain types of events?

**Answer:** With **SNS subscription filter policies**. When publishing, I'd add a message attribute such as `category = "workshop"`. Each subscription gets a filter policy such as `{"category": ["workshop"]}`, and SNS delivers only matching messages, with no extra code in the Lambda.

---

## 7. IAM and security

### Q25. Explain the IAM policy for the create-event Lambda.

```json
{ "Action": ["s3:GetObject", "s3:PutObject"], "Resource": "arn:aws:s3:::<bucket>/events.json" }
{ "Action": "s3:ListBucket",                  "Resource": "arn:aws:s3:::<bucket>" }
{ "Action": "sns:Publish",                    "Resource": "<topic-arn>" }
```

**Answer:** The policy has three statements:
- **Read and write one object only:** `GetObject` and `PutObject` on `events.json`, not the whole bucket. A bug or exploit in this function can't overwrite `index.html` and deface the site.
- **`ListBucket` on the bucket:** without it, S3 returns `403 Access Denied` instead of `404 Not Found` for a missing object. The code relies on the 404 to know it should create the file the first time.
- **`Publish` on one topic only:** the function can't subscribe or unsubscribe anyone, and can't publish to any other topic.

The role also has `AWSLambdaBasicExecutionRole` so the function can write to CloudWatch Logs.

### Q26. Why does `ListBucket` use the bucket ARN, while `GetObject` uses an object ARN?

**Answer:** Because of what each action operates on. `ListBucket` acts on the **bucket** (`arn:aws:s3:::bucket`). `GetObject` and `PutObject` act on **objects** (`arn:aws:s3:::bucket/key`). A common mistake is putting `ListBucket` on `bucket/*`, which silently doesn't work.

### Q27. What's the difference between a trust policy, an identity-based policy and a resource-based policy?

**Answer:**
- **Trust policy:** on a role, saying *who may assume it*. Mine allows only `lambda.amazonaws.com`.
- **Identity-based policy:** on a role, user or group, saying *what that identity can do*. Example: the create-event role may call `sns:Publish` on the topic.
- **Resource-based policy:** on the resource itself, saying *who can access it*. Two examples here: the S3 bucket policy (anyone may read), and the Lambda permission (API Gateway may invoke).

### Q28. How do you apply least privilege in this project?

**Answer:**
- **Separate roles:** each Lambda has its own role, and neither has the other's permissions.
- **Named resources:** every statement names a specific resource, never `*`. That's one topic, one bucket, and one object for writes.
- **No broad managed policies:** I avoided policies like `AmazonS3FullAccess`.
- **Scoped invoke permissions:** each Lambda can only be invoked from its own route.
- **Read-only public access:** the public can read objects only, with no list and no write.

### Q29. How would you prevent abuse of the public API, such as spamming events to all subscribers?

**Answer:**
1. **Authentication:** a Cognito JWT authorizer on `/create-event`, so only signed-in organizers can post.
2. **Throttling:** set rate and burst limits on the API Gateway stage.
3. **WAF:** HTTP APIs can't attach WAF directly, so I'd put CloudFront in front and use rate-based rules there, or use a REST API.
4. **CAPTCHA** on the forms.
5. **Restricted CORS:** limit it to my domain. This doesn't stop `curl`, but it stops other websites from calling my API from their pages.
6. **Moderation:** an approval step before notifications go out.

### Q30. How did you prevent XSS, given that users submit content that's shown to others?

**Answer:** Event text is rendered with `textContent`, never `innerHTML`, so any HTML or `<script>` in a title or description is displayed as plain text instead of running. The Lambda also limits field lengths.

### Q31. Are there any secrets in your repository?

**Answer:** No. The IAM policy templates use placeholders such as `__BUCKET_NAME__` and `__TOPIC_ARN__`, which the deploy script fills in at deploy time into a git-ignored `.build/` folder. Lambdas get their configuration from environment variables and their credentials from their IAM role, so there are no access keys anywhere. I scanned the repo for account IDs and keys before pushing it public.

---

## 8. Concurrency and data consistency

### Q32. What is a race condition, and where could one happen in your project?

**Answer:** A race condition is when the result depends on the timing of operations that run at the same time. In this project it's the read-modify-write on `events.json`:
1. Lambda A reads `[e1]`.
2. Lambda B reads `[e1]`.
3. A writes `[e1, eA]`.
4. B writes `[e1, eB]`.

Event A is lost, and nobody gets an error.

### Q33. How do S3 conditional writes solve it?

**Answer:** It's **optimistic locking**. When the Lambda reads the file, it keeps the ETag, a fingerprint of the content. It writes with `If-Match: <that ETag>`. If another write happened in between, the ETag no longer matches, and S3 rejects the write with `412 Precondition Failed`. The Lambda then re-reads the latest version, appends again and retries, up to 5 times.

For the very first write, when the file doesn't exist yet, it uses `If-None-Match: *`, meaning "only create the file if it doesn't exist".

### Q34. Why optimistic locking instead of a lock?

**Answer:** Conflicts are rare: two people creating an event in the same few milliseconds. Optimistic locking costs nothing when there's no conflict, and only retries when there is one. A real lock, such as a lock item in DynamoDB, adds another service, plus the problem of locks that are never released if a Lambda crashes.

### Q35. How did you test the concurrency handling?

**Answer:** In the unit tests, a fake S3 client is set to fail the next `PutObject` with `PreconditionFailed` and change the ETag, simulating another writer. The test checks that the Lambda retries, that the retry uses the new ETag, and that both events end up in the file.

---

## 9. Monitoring and troubleshooting

### Q36. How would you debug "I created an event but nobody got an email"?

**Answer:** I'd work along the path, step by step:
1. **Is the event in `events.json`?** If not, it failed before SNS. Check the API response and the create-event Lambda logs.
2. **Check the Lambda logs** in CloudWatch: `aws logs tail /aws/lambda/<fn>`. Look for `SNS publish failed`, which is often an IAM `AuthorizationError`.
3. **Check the subscriptions:** are any confirmed? A *Pending confirmation* subscription receives nothing.
4. **Check SNS metrics:** `NumberOfMessagesPublished` and `NumberOfNotificationsFailed`.
5. **Check the recipient's spam folder.**

### Q37. What problems did you run into or design around while building it?

**Answer:** Four come to mind:
- **IAM propagation delay:** a newly created role can't be assumed by Lambda for a few seconds, because IAM is eventually consistent. Creating the function immediately can fail with "role cannot be assumed", so the deploy script waits and retries.
- **A DOM gotcha:** `form.title` returns the form element's own `title` attribute, not the input named `title`. I switched to `form.elements.title`.
- **Caching:** a cached `events.json` would hide newly created events, so I added `no-cache` headers and a cache-buster on the fetch.
- **S3 website endpoints:** the URL format differs by region (`s3-website-` vs `s3-website.`), so the script handles both.

> Add any real errors you hit during your own deployment here. A specific error message and how you fixed it is the strongest answer to this question.

### Q38. What monitoring would you add for production?

**Answer:**
- **Alarms:** CloudWatch alarms on Lambda `Errors`, API Gateway `5xx`, and SNS `NumberOfNotificationsFailed`, notifying an ops topic.
- **Log retention:** the default is never expire, so I'd set something like 14–30 days.
- **Logging and tracing:** structured JSON logs, API Gateway access logs, and X-Ray tracing to follow one request across services.
- **A dashboard** combining all of these.

---

## 10. Deployment, testing and CI/CD

### Q39. How is it deployed? Why a script instead of clicking in the console?

**Answer:** It's deployed by a Bash script using the AWS CLI. It creates or updates the bucket, topic, roles, Lambdas and API, then uploads the frontend with the API URL filled in. It's **idempotent**: it checks whether each resource exists before creating it, so I can re-run it after any change. It also never overwrites `events.json`, so redeploying doesn't wipe real data.

A script is repeatable and reviewable. Console clicks aren't.

### Q40. Why not Terraform or CloudFormation?

**Answer:** For a first build, the CLI script made every AWS API call visible, which helped me learn what each resource actually needs. The script's weaknesses are that it doesn't track state or detect drift, and deletion has to be handled separately. For production I'd use Terraform or AWS SAM, which bring plan/apply, state tracking and dependency ordering, and handle teardown for free.

### Q41. How did you test it?

**Answer:** In three layers:
- **Unit tests** for both Lambdas, using fake S3 and SNS clients, so no AWS account is needed. They cover valid input, invalid input, the first-ever write, the concurrent-write retry and the notification content.
- **Static checks:** shell syntax, Python compile and JSON validity for the policy files.
- **End-to-end checks** on the deployed stack: subscribe and confirm, create an event, check that it appears in `events.json` and that the email arrives, and check that a bad payload gets a `400`.

### Q42. What would your CI/CD pipeline look like?

**Answer:** I'd use GitHub Actions:
- **On pull requests:** run unit tests, `shellcheck` and policy linting.
- **On merge to `main`:** authenticate to AWS with **GitHub OIDC**, which gives short-lived credentials with no stored access keys. Then deploy and run a smoke test: load the site and confirm that an invalid POST returns `400`.

Ideally I'd also add a staging environment that gets deployed first.

---

## 11. Cost

### Q43. How much does this cost to run?

**Answer:** At lab traffic levels, close to $0. Every service bills per use and nothing charges while idle:
- **Lambda:** 1M free requests per month.
- **API Gateway:** about $1 per million requests.
- **SNS:** 1,000 free emails per month.
- **S3:** a few KB of storage.

The main ongoing cost risk is CloudWatch Logs, which never expire by default. A spammed public API could also send lots of emails, which is why authentication and throttling matter.

### Q44. How do you make sure you don't leave resources running?

**Answer:** There's a teardown script that deletes the resources in dependency order:
1. The API
2. The Lambdas
3. The roles (inline policies deleted and managed policies detached first)
4. The topic
5. The bucket and everything in it
6. The log groups

The README also lists CLI commands to check that nothing is left.

---

## 12. Scaling and production readiness

### Q45. What happens if this suddenly gets 10,000 events per minute?

**Answer:** API Gateway, Lambda, SNS and S3 reads all scale automatically. Lambda's default limit is 1,000 concurrent executions per region. The bottleneck is **`events.json`**: every write rewrites the whole file, and under heavy concurrency most conditional writes would conflict and run out of retries. The file also keeps growing, so page loads get slower.

The fix is to store each event as a DynamoDB item, add a paginated `GET /events` endpoint, and send notifications asynchronously through SQS.

### Q46. What would you add before calling this production-ready?

**Answer:**
1. **HTTPS and a custom domain:** CloudFront, ACM and Route 53, with a private bucket.
2. **Authentication** on `/create-event` (Cognito).
3. **Abuse protection:** throttling, plus WAF through CloudFront.
4. **DynamoDB** instead of the JSON file.
5. **Infrastructure as code and CI/CD with OIDC.**
6. **Monitoring:** alarms, log retention and tracing.
7. **Restricted CORS**, limited to my domain.
8. **Reliable notifications:** asynchronous, with retries and a dead-letter queue.

### Q47. How would you make notification delivery more reliable?

**Answer:** Separate saving from notifying. The create-event Lambda would only save the event and put a message on an **SQS queue**, or the event would come from a DynamoDB Stream. A separate Lambda consumes it and publishes to SNS, with automatic retries and a **dead-letter queue** for messages that keep failing. A temporary SNS problem would then never cause a lost notification or a confusing error for the user.

---

## 13. Behavioral questions

### Q48. Tell me about a bug you found that wasn't obvious.

**Answer (STAR):**
- **Situation:** the create-event form read each field by name, as in `form.title.value`.
- **Task:** while reviewing the code before deploying, I checked that every field would actually reach the API.
- **Action:** I realized `form.title` isn't the input element. HTML form elements have a built-in `title` property (the form's tooltip attribute), and it takes priority over named-field access. The title would have been sent empty or wrong, even though the code looked correct.
- **Result:** I switched to `form.elements.title`, which always returns the field, and added a code comment explaining why.

The lesson: always use `form.elements` for field access.

### Q49. Tell me about a time you thought about failure cases, not just the happy path.

**Answer:** With `events.json`, the happy path worked in testing, but I asked myself what would happen if two people submitted at once. Following the timeline showed one event would be silently lost. Silent data loss is the worst kind of bug, because nobody notices.

I added conditional writes with retries, and a unit test that forces the conflict. I also decided what should happen if SNS fails after the save. I chose to report a partial success instead of an error, to avoid duplicate submissions.

### Q50. What did you learn from this project?

**Answer:**
- **The real work is the glue.** Even without servers, most of the effort went into IAM, permissions, CORS and caching.
- **IAM denies by default,** and least privilege can be scoped down to a single object.
- **A file used as a database needs concurrency control.**
- **AWS is eventually consistent in places, such as IAM,** so automation needs retries.
- **Idempotent deploy scripts** make it safe to iterate.

---

## Quick-fire questions

| Question | Short answer |
|---|---|
| What's an ARN? | Amazon Resource Name: the unique ID of an AWS resource, e.g. `arn:aws:sns:us-east-1:123456789012:topic-name` |
| What's an ETag? | A fingerprint of an S3 object's content. It changes whenever the object changes. |
| HTTP status for a failed precondition? | `412 Precondition Failed` |
| Default Lambda timeout? Maximum? | 3 seconds; 15 minutes |
| Maximum integration timeout for an HTTP API? | 30 seconds |
| Can a FIFO SNS topic send emails? | No. FIFO topics deliver only to SQS (FIFO or standard). |
| Does IAM allow or deny by default? | Deny. An explicit Deny always overrides an Allow. |
| Where do Lambda `print()` statements go? | CloudWatch Logs, in `/aws/lambda/<function-name>` |
| What does `AWSLambdaBasicExecutionRole` grant? | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` |
| Is the S3 website endpoint HTTPS? | No, HTTP only. Use CloudFront for HTTPS. |
| What does idempotent mean? | Running it again gives the same result without side effects |
