# Amazon API Gateway (HTTP API)

## What it is

API Gateway is a managed service for publishing HTTP APIs. It receives requests from clients and passes them to a backend, in this case Lambda functions. It also handles TLS (HTTPS), CORS, throttling and scaling.

## Why this project needs it

The frontend is static files in S3, which can't run code. Subscribing and creating events need backend logic, and that logic lives in Lambda functions. Browsers can't call Lambda directly: Lambda has no public URL by default, and calling it through the AWS API would need AWS credentials.

API Gateway closes that gap. It gives the browser a public HTTPS URL, and each path is wired to the right Lambda:

| Route | Backend | Purpose |
|---|---|---|
| `POST /subscribe` | `event-announcement-subscribe` | Add an email to the SNS topic |
| `POST /create-event` | `event-announcement-create-event` | Save an event and notify subscribers |

## What was created

| Item | Value |
|---|---|
| API | `event-announcement-api` (protocol: **HTTP**) |
| Endpoint | `https://<api-id>.execute-api.us-east-1.amazonaws.com` |
| Integrations | 2 × `AWS_PROXY` (Lambda proxy), payload format **2.0** |
| Routes | `POST /subscribe`, `POST /create-event` |
| Stage | `$default` with **auto-deploy** on |

## Configuration and why

| Setting | Value | Why |
|---|---|---|
| API type | **HTTP API** (not REST API) | Cheaper per request, lower latency and built-in CORS. The extra features of a REST API, such as usage plans, request validation and caching, aren't needed here. |
| Integration type | `AWS_PROXY` | API Gateway forwards the whole request to Lambda unchanged and returns Lambda's response as is. All logic stays in one place, the Lambda. |
| Payload format | `2.0` | The simpler event format for HTTP APIs |
| CORS | `AllowOrigins=*`, `AllowMethods=POST,OPTIONS`, `AllowHeaders=content-type` | The site is served from `s3-website-...amazonaws.com` and the API from `execute-api...amazonaws.com`. These are different origins, so the browser sends an `OPTIONS` preflight before each `POST`. With CORS configured, API Gateway answers the preflight itself, and the `POST` is allowed. |
| Stage | `$default`, auto-deploy | The API is served at the root URL with no `/prod` prefix, and route changes go live without a manual "deploy" step |

## How it connects to other resources

- **Browser → API Gateway:** `fetch(API_BASE_URL + "/subscribe", { method: "POST", ... })` in [index.html](../frontend/index.html). `deploy.sh` writes the API URL into the page.
- **API Gateway → Lambda:** invokes the function. Lambda only accepts the call because of a **resource-based permission** on each function. It allows `apigateway.amazonaws.com` to invoke the function, but only for this API's matching route (`arn:aws:execute-api:<region>:<account>:<api-id>/*/*/subscribe`). See [05-aws-iam.md](05-aws-iam.md).

## Alternatives considered

| Option | Why it wasn't used |
|---|---|
| REST API (API Gateway v1) | Costs more and needs more setup (methods, a separate OPTIONS mock for CORS, explicit deployments). None of its extra features are needed. |
| Lambda function URLs | Simpler, but you get one URL per function instead of one API with clean paths. The lab's architecture also specifies API Gateway. |
| Application Load Balancer | Has an hourly charge even when idle. It's built for high-traffic services. |

## Limitations

- **No authentication:** anyone with the URL can call both routes. In production, add a JWT authorizer (Cognito) to `/create-event`.
- **No custom throttling:** the account-level defaults apply. In production, set stage throttling limits or add AWS WAF.
- **CORS allows any origin (`*`):** in production, restrict it to the site's domain.

## Cost

HTTP APIs are billed per request (about $1.00 per million in us-east-1 for the first 300M). There's no charge while idle. At lab traffic levels the cost is effectively $0.

## Inspect it

**CLI:**
```bash
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='event-announcement-api'].ApiId | [0]" --output text)
aws apigatewayv2 get-api --api-id $API_ID              # endpoint + CORS
aws apigatewayv2 get-routes --api-id $API_ID --query 'Items[].RouteKey'
aws apigatewayv2 get-integrations --api-id $API_ID --query 'Items[].IntegrationUri'

# Call it directly (should return 400 for an invalid body)
curl -s -X POST "https://$API_ID.execute-api.us-east-1.amazonaws.com/create-event" \
     -H 'Content-Type: application/json' -d '{}'
```

**Console:** go to **API Gateway**, then **APIs**, then `event-announcement-api`.
- **Routes** shows both routes.
- **Integrations** shows which Lambda each route calls.
- **CORS** shows the CORS settings.
- **Stages** shows the `$default` stage.

## Cleanup

`scripts/teardown.sh` runs `aws apigatewayv2 delete-api`. This also deletes the routes, integrations and stage.
