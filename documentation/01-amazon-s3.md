# Amazon S3 (Simple Storage Service)

## What it is

S3 is AWS's object storage service. You store files ("objects") in containers ("buckets") and read them over HTTP. A bucket can also act as a basic web server through **static website hosting**.

## Why this project needs it

S3 does two jobs here:

1. **Frontend hosting:** it serves `index.html` and `styles.css` to visitors. The site is plain HTML, CSS and JavaScript with no server-side code, so a static host is all it needs. There's no EC2 instance to run, patch or pay for while idle.
2. **Data storage:** it stores `events.json`, the list of all events. The browser reads this file directly to show events, and the Event Registration Lambda rewrites it when someone creates an event.

Keeping data in a JSON file in the same bucket means the event list loads with a single plain HTTP GET. No database and no extra API call are needed just to view events.

## What was created

| Item | Value |
|---|---|
| Bucket | `event-announcement-site-<account-id>-<region>` |
| Website endpoint | `http://<bucket>.s3-website-us-east-1.amazonaws.com` |
| Objects | `index.html`, `styles.css`, `events.json` |

## Configuration and why

| Setting | Value | Why |
|---|---|---|
| Static website hosting | Index document `index.html`, error document `index.html` | Gives the bucket a website URL that serves `index.html` at `/` |
| Block Public Access | `BlockPublicAcls=true`, `IgnorePublicAcls=true`, `BlockPublicPolicy=false`, `RestrictPublicBuckets=false` | A public website needs a public *bucket policy*, so only the two policy-related blocks are turned off. Public *ACLs* stay blocked, so no individual object can be made public or writable through an ACL. |
| Bucket policy | Allow `s3:GetObject` for `Principal: *` on `<bucket>/*` | Lets anyone **read** the site files. It grants no list, write or delete access. See [iam/s3-bucket-policy.json](../iam/s3-bucket-policy.json). |
| `events.json` metadata | `Content-Type: application/json`, `Cache-Control: no-cache, no-store, must-revalidate` | Browsers parse the file as JSON and always fetch the latest version, so new events appear right away |
| `index.html` / `styles.css` metadata | `Cache-Control: no-cache` | Redeployed changes show up without users having to clear their cache |

### Safe concurrent writes to `events.json`

If two people create an event at the same moment, both Lambdas could read the same version of the file. Each would then write back its own version, and one event would be lost. The Lambda prevents this with **S3 conditional writes**:

- It reads the file and remembers its **ETag**, a fingerprint of the content.
- It writes with `If-Match: <ETag>`. S3 rejects the write with `412 Precondition Failed` if someone changed the file in the meantime.
- On a rejection, the Lambda re-reads the file and tries again, up to 5 times.
- For the very first write, it uses `If-None-Match: *`, which means "only create the file if it doesn't exist yet".

## How it connects to other resources

- **Browser → S3:** loads the site and fetches `events.json` (public read through the bucket policy).
- **Create-event Lambda → S3:** `GetObject` and `PutObject` on `events.json` only, granted by its [IAM role](05-aws-iam.md).
- **deploy.sh → S3:** uploads the frontend. It uploads `events.json` only if the file doesn't exist yet, so a redeploy never wipes real events.

## Alternatives considered

| Option | Why it wasn't used |
|---|---|
| EC2 or a container running a web server | Costs money 24/7 and needs patching. That's overkill for static files. |
| DynamoDB for event data | A better fit in production (see [Future Improvements](../README.md#future-improvements)), but it needs an extra "list events" API. The lab asks for `events.json` in S3. |
| CloudFront in front of S3 | Adds HTTPS and caching. It was left out to keep the lab simple, and is a recommended next step. |

## Limitations

- S3 website endpoints are **HTTP only**. HTTPS requires CloudFront.
- A single JSON file grows without limit, and every write rewrites the whole file. This is fine for hundreds of events but not for millions.

## Cost

- **Storage:** a few KB, so effectively $0.
- **Requests:** GET and PUT requests cost fractions of a cent per thousand.
- **Data transfer out:** the site is about 12 KB per visit. The Free Tier covers 100 GB per month.

## Inspect it

**CLI:**
```bash
B=event-announcement-site-<account-id>-us-east-1
aws s3 ls s3://$B/                              # list objects
aws s3 cp s3://$B/events.json -                 # print events.json
aws s3api head-object --bucket $B --key events.json   # metadata, ETag
aws s3api get-bucket-policy --bucket $B --query Policy --output text
aws s3api get-bucket-website --bucket $B
```

**Console:** go to **S3**, then **Buckets**, then your bucket.
- The **Objects** tab lists the files.
- The **Properties** tab shows *Static website hosting* (at the bottom).
- The **Permissions** tab shows the bucket policy and Block Public Access.

## Cleanup

`scripts/teardown.sh` runs `aws s3 rb s3://<bucket> --force`. This deletes every object, including events created through the site, and then the bucket itself.
