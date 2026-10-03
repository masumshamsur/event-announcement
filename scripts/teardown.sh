#!/usr/bin/env bash
# Deletes everything created by deploy.sh, including the bucket and all events in it.
# Usage:  ./scripts/teardown.sh   (use the same AWS_REGION / PROJECT / BUCKET_NAME as deploy)
set -uo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PROJECT="${PROJECT:-event-announcement}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || exit 1
BUCKET="${BUCKET_NAME:-${PROJECT}-site-${ACCOUNT_ID}-${REGION}}"
export AWS_REGION="$REGION" AWS_PAGER=""

read -r -p "Delete all '$PROJECT' resources in $REGION, including bucket $BUCKET? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='${PROJECT}-api'].ApiId | [0]" --output text)"
[[ -n "$API_ID" && "$API_ID" != "None" ]] && aws apigatewayv2 delete-api --api-id "$API_ID" && echo "Deleted API $API_ID"

for fn in "${PROJECT}-subscribe" "${PROJECT}-create-event"; do
  aws lambda delete-function --function-name "$fn" 2>/dev/null && echo "Deleted Lambda $fn"
done

for role in "${PROJECT}-subscribe-lambda-role" "${PROJECT}-create-event-lambda-role"; do
  aws iam delete-role-policy --role-name "$role" --policy-name "${role}-inline" 2>/dev/null
  aws iam detach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
  aws iam delete-role --role-name "$role" 2>/dev/null && echo "Deleted role $role"
done

TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT}-notifications"
aws sns delete-topic --topic-arn "$TOPIC_ARN" 2>/dev/null && echo "Deleted topic $TOPIC_ARN"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3 rb "s3://$BUCKET" --force && echo "Deleted bucket $BUCKET"
fi

for fn in "${PROJECT}-subscribe" "${PROJECT}-create-event"; do
  aws logs delete-log-group --log-group-name "/aws/lambda/$fn" 2>/dev/null && echo "Deleted log group for $fn"
done

echo "Teardown complete."
