# Amazon CloudWatch Logs

## What it is

CloudWatch Logs collects, stores and searches log output from AWS services. Logs are organized into **log groups**, one per application or function, and each group holds **log streams**, one per running Lambda instance.

## Why this project needs it

Lambda functions have no server you can log in to, and they disappear between requests. Without CloudWatch Logs you'd have no way to see:

- Why a request returned `500`, such as an S3 or SNS permission error
- Whether the `events.json` write conflict retry happened
- How long each invocation took and how much memory it used
- Errors from Lambda itself, such as timeouts or crashes

Anything the Lambda code `print()`s goes to CloudWatch Logs automatically, along with a START, END and REPORT line for every invocation.

## What was created

Lambda creates the log groups the first time each function runs. `deploy.sh` doesn't create them.

| Log group | Source |
|---|---|
| `/aws/lambda/event-announcement-subscribe` | Subscription Lambda |
| `/aws/lambda/event-announcement-create-event` | Event Registration Lambda |

Permission to write them comes from the AWS managed policy `AWSLambdaBasicExecutionRole`, which is attached to both Lambda roles. See [05-aws-iam.md](05-aws-iam.md).

## What gets logged

| Message | Logged by | Meaning |
|---|---|---|
| `SNS subscribe failed for <email>: ...` | subscribe | SNS rejected the call, for example due to permissions or an invalid topic |
| `events.json changed during write (attempt N); retrying` | create-event | Another request updated the file first. This is normal under concurrent use. |
| `Failed to update events.json: ...` | create-event | The S3 read or write failed. The user sees a 500. |
| `SNS publish failed: ...` | create-event | The event was saved, but notifications weren't sent |
| `REPORT RequestId: ... Duration: ... Max Memory Used: ...` | Lambda | Added automatically to every invocation |

### Metrics (collected automatically, no setup needed)

These come from CloudWatch **Metrics**, not Logs, but you see them in the same console:

- **Lambda:** `Invocations`, `Errors`, `Duration`, `Throttles`
- **API Gateway:** `Count`, `4xx`, `5xx`, `Latency`
- **SNS:** `NumberOfMessagesPublished`, `NumberOfNotificationsDelivered`, `NumberOfNotificationsFailed`

## Configuration and why

| Setting | Current value | Recommendation |
|---|---|---|
| Retention | **Never expire** (the default) | Set to 7–30 days so old logs don't build up storage costs: `aws logs put-retention-policy --log-group-name <group> --retention-in-days 14` |
| Alarms | None | Add alarms on Lambda `Errors > 0`, API Gateway `5xx > 0` and SNS `NumberOfNotificationsFailed > 0` (see [Future Improvements](../README.md#future-improvements)) |
| API Gateway access logs | Off | Turn them on for the `$default` stage to log each HTTP request (IP, route, status, latency) |

## Alternatives considered

| Option | Why it wasn't used |
|---|---|
| Third-party logging tools such as Datadog or ELK | Need an extra agent or log forwarding plus a paid service. CloudWatch is built in. |
| AWS X-Ray tracing | Useful for following a request across API Gateway, Lambda, S3 and SNS. It's a good next step, but not needed to debug two small functions. |

## Cost

The Free Tier includes **5 GB of log ingestion and storage per month**. This project writes a few KB per request, so the cost is $0. Logs are kept forever by default, so set a retention period or delete the groups when you're done.

## Inspect it

**CLI:**
```bash
aws logs tail /aws/lambda/event-announcement-create-event --follow        # live
aws logs tail /aws/lambda/event-announcement-create-event --since 1h      # last hour
aws logs filter-log-events --log-group-name /aws/lambda/event-announcement-create-event \
  --filter-pattern "failed"                                               # search
```

**Console:**
- Go to **CloudWatch**, then **Logs → Log groups**, then the group, then a log stream.
- For searches across groups, use **CloudWatch → Logs Insights**:
  ```
  fields @timestamp, @message
  | filter @message like /failed|retrying/
  | sort @timestamp desc
  ```

## Cleanup

`scripts/teardown.sh` deletes both log groups. Delete the Lambda functions **first**, as the script does. Otherwise a function that's still running could recreate its log group.
