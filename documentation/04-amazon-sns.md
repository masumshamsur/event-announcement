# Amazon SNS (Simple Notification Service)

## What it is

SNS is a publish/subscribe messaging service. You create a **topic**, and endpoints such as email addresses, phone numbers, Lambda functions or SQS queues **subscribe** to it. When a message is **published** to the topic, SNS delivers a copy to every subscriber.

## Why this project needs it

The site has to email everyone who signed up whenever a new event is posted. Doing that yourself would mean storing an email list, sending to each address, and handling confirmations and unsubscribes. SNS covers all of it:

- **It stores the subscriber list.** The project needs no database of emails.
- **One `Publish` call reaches every subscriber,** so the Lambda doesn't loop over addresses.
- **It handles double opt-in.** Every new email address gets a confirmation link and receives nothing until it's clicked. This stops people from being subscribed without their consent.
- **It handles unsubscribes.** Every notification email includes an unsubscribe link, and SNS removes the address automatically when it's clicked.

## What was created

| Item | Value |
|---|---|
| Topic | `event-announcement-notifications` (type: **Standard**) |
| Topic ARN | `arn:aws:sns:us-east-1:<account-id>:event-announcement-notifications` |
| Subscriptions | One per visitor who subscribes. Protocol: `email`. |

## How it's used

| Action | Called by | API call |
|---|---|---|
| Add a subscriber | Subscription Lambda | `sns.subscribe(TopicArn, Protocol="email", Endpoint=email, ReturnSubscriptionArn=True)` |
| Notify everyone | Event Registration Lambda | `sns.publish(TopicArn, Subject="New event: <title>", Message=<details>)` |

### Subscription lifecycle

1. A visitor submits their email, and the Lambda calls `Subscribe`. The subscription is now **Pending confirmation**.
2. SNS sends an email titled *"AWS Notification – Subscription Confirmation"*.
3. The visitor clicks **Confirm subscription**, and the subscription becomes **Confirmed**.
4. From then on, every `Publish` sends them an email.
5. If they click the unsubscribe link in any notification, the subscription is deleted.

A pending subscription that isn't confirmed expires after 3 days.

### The notification email

```
Subject: New event: IT job fair

A new event has been announced!

IT job fair
When: Wednesday, October 21, 2026

A job fair for the fresh graduate in Florida.
```

The subject is trimmed to 99 characters and has its line breaks removed, because SNS email subjects must be under 100 characters on a single line.

## Configuration and why

| Setting | Value | Why |
|---|---|---|
| Topic type | Standard (not FIFO) | FIFO topics don't support email subscriptions, and strict ordering isn't needed |
| Protocol | `email` (plain text) | The simplest option that needs no extra setup. `email-json` would send raw JSON. |
| Access | IAM roles only. There's no topic policy change. | Only the two Lambdas can use the topic: one can only `Subscribe`, the other can only `Publish`. See [05-aws-iam.md](05-aws-iam.md). |
| Creation | `aws sns create-topic` | Running it again with the same name returns the existing topic, so the deploy script can safely re-run |

## How it connects to other resources

- **Subscription Lambda → SNS:** `sns:Subscribe` on this topic only
- **Event Registration Lambda → SNS:** `sns:Publish` on this topic only
- **SNS → subscribers' inboxes:** email delivery, managed by AWS

## Alternatives considered

| Option | Why it wasn't used |
|---|---|
| Amazon SES | Supports HTML emails, a custom sender address and templates, but you have to manage the subscriber list yourself and verify a domain. SNS is simpler for a lab. |
| A database of emails plus a sending loop | More code, plus confirmations and unsubscribes to handle yourself, all of which SNS includes |
| Third-party mailing services | Outside AWS, and needs API keys and secrets management |

## Limitations

- Emails come from `no-reply@sns.amazonaws.com` with a generic AWS look, and you can't customize the sender or use HTML.
- Every subscriber gets every event. SNS **filter policies** could add categories, such as only workshops.
- New AWS accounts have default delivery limits for email. That's fine for a lab, but large lists would need SES.

## Cost

The Free Tier includes **1,000 email notifications per month**. After that, email is billed per 100,000 notifications. Publish requests are also nearly free (the first 1M per month). At lab usage the cost is $0.

## Inspect it

**CLI:**
```bash
TOPIC=arn:aws:sns:us-east-1:<account-id>:event-announcement-notifications
aws sns get-topic-attributes --topic-arn $TOPIC \
  --query 'Attributes.{Confirmed:SubscriptionsConfirmed,Pending:SubscriptionsPending}'
aws sns list-subscriptions-by-topic --topic-arn $TOPIC

# Send a test notification to all confirmed subscribers
aws sns publish --topic-arn $TOPIC --subject "Test" --message "Hello from SNS"
```

**Console:** go to **SNS**, then **Topics**, then `event-announcement-notifications`. The **Subscriptions** tab shows each email address and whether it's *Confirmed* or *Pending confirmation*.

## Cleanup

`scripts/teardown.sh` runs `aws sns delete-topic`, which also deletes all of the topic's subscriptions.
