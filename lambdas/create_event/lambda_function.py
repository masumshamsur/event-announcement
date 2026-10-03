"""Event Registration Lambda: appends an event to events.json in S3 and notifies subscribers.

Triggered by API Gateway: POST /create-event
    {"title": "...", "date": "YYYY-MM-DD", "description": "..."}

Environment variables:
    BUCKET_NAME      S3 bucket hosting the website
    EVENTS_KEY       object key of the events file (default "events.json")
    SNS_TOPIC_ARN    ARN of the event notifications topic
    ALLOWED_ORIGIN   CORS origin to allow (default "*")
"""
import base64
import json
import os
import uuid
from datetime import date, datetime, timezone

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
sns = boto3.client("sns")

BUCKET = os.environ["BUCKET_NAME"]
EVENTS_KEY = os.environ.get("EVENTS_KEY", "events.json")
TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")

FIELD_LIMITS = {"title": 120, "date": 10, "description": 1000}
MAX_WRITE_ATTEMPTS = 5


def response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Allow-Methods": "OPTIONS,POST",
        },
        "body": json.dumps(body),
    }


def parse_body(event):
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    return json.loads(body)


def validate(data):
    """Return (clean_event, error_message)."""
    clean = {}
    for field, limit in FIELD_LIMITS.items():
        value = str(data.get(field, "")).strip()
        if not value:
            return None, f"'{field}' is required."
        if len(value) > limit:
            return None, f"'{field}' must be at most {limit} characters."
        clean[field] = value
    try:
        date.fromisoformat(clean["date"])
    except ValueError:
        return None, "'date' must be in YYYY-MM-DD format."
    return clean, None


def read_events():
    """Return (events, etag). A missing file is treated as an empty list."""
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=EVENTS_KEY)
    except ClientError as err:
        if err.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return [], None
        raise
    events = json.loads(obj["Body"].read() or b"[]")
    return (events if isinstance(events, list) else []), obj["ETag"]


def append_event(new_event):
    """Append with an optimistic lock so two simultaneous submissions can't overwrite each other."""
    for attempt in range(1, MAX_WRITE_ATTEMPTS + 1):
        events, etag = read_events()
        events.append(new_event)
        put_args = {
            "Bucket": BUCKET,
            "Key": EVENTS_KEY,
            "Body": json.dumps(events, indent=2).encode("utf-8"),
            "ContentType": "application/json",
            "CacheControl": "no-cache, no-store, must-revalidate",
        }
        # Conditional write: fails with 412 if someone else wrote the file since we read it.
        if etag:
            put_args["IfMatch"] = etag
        else:
            put_args["IfNoneMatch"] = "*"
        try:
            s3.put_object(**put_args)
            return
        except ClientError as err:
            code = err.response["Error"]["Code"]
            if code in ("PreconditionFailed", "ConditionalRequestConflict", "412", "409") and attempt < MAX_WRITE_ATTEMPTS:
                print(f"events.json changed during write (attempt {attempt}); retrying")
                continue
            raise


def notify(evt):
    pretty_date = date.fromisoformat(evt["date"]).strftime("%A, %B %d, %Y")
    message = (
        f"A new event has been announced!\n\n"
        f"{evt['title']}\n"
        f"When: {pretty_date}\n\n"
        f"{evt['description']}\n"
    )
    # Email subjects must be < 100 chars and contain no line breaks.
    subject = f"New event: {evt['title']}".replace("\n", " ")[:99]
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject, Message=message)


def lambda_handler(event, context):
    method = event.get("httpMethod") or event.get("requestContext", {}).get("http", {}).get("method")
    if method == "OPTIONS":
        return response(200, {})

    try:
        data = parse_body(event)
    except (ValueError, TypeError):
        return response(400, {"error": "Request body must be valid JSON."})
    if not isinstance(data, dict):
        return response(400, {"error": "Request body must be a JSON object."})

    clean, error = validate(data)
    if error:
        return response(400, {"error": error})

    new_event = {
        "id": str(uuid.uuid4()),
        **clean,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    try:
        append_event(new_event)
    except ClientError as err:
        print(f"Failed to update {EVENTS_KEY}: {err}")
        return response(500, {"error": "Could not save the event. Try again later."})

    # The event is saved even if notification fails, so report success with a note.
    try:
        notify(new_event)
    except ClientError as err:
        print(f"SNS publish failed: {err}")
        return response(200, {"message": "Event published, but subscribers could not be notified.", "event": new_event})

    return response(200, {"message": "Event published and subscribers notified.", "event": new_event})
