"""Subscription Lambda: adds an email address to the SNS topic.

Triggered by API Gateway: POST /subscribe  {"email": "you@example.com"}
SNS emails the address a confirmation link; nothing is delivered until they click it.

Environment variables:
    SNS_TOPIC_ARN    ARN of the event notifications topic
    ALLOWED_ORIGIN   CORS origin to allow (default "*")
"""
import base64
import json
import os
import re

import boto3
from botocore.exceptions import ClientError

sns = boto3.client("sns")

TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


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


def lambda_handler(event, context):
    # REST API proxy integrations pass the preflight through to Lambda.
    method = event.get("httpMethod") or event.get("requestContext", {}).get("http", {}).get("method")
    if method == "OPTIONS":
        return response(200, {})

    try:
        data = parse_body(event)
    except (ValueError, TypeError):
        return response(400, {"error": "Request body must be valid JSON."})

    email = str(data.get("email", "")).strip().lower()
    if not EMAIL_RE.match(email) or len(email) > 254:
        return response(400, {"error": "Enter a valid email address."})

    try:
        sns.subscribe(
            TopicArn=TOPIC_ARN,
            Protocol="email",
            Endpoint=email,
            ReturnSubscriptionArn=True,
        )
    except ClientError as err:
        print(f"SNS subscribe failed for {email}: {err}")
        return response(500, {"error": "Could not subscribe right now. Try again later."})

    return response(200, {
        "message": f"Almost done: check {email} for a confirmation email from AWS and click the link."
    })
