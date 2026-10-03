#!/usr/bin/env bash
# Deploys the Event Announcement website end to end with the AWS CLI.
# Safe to re-run: existing resources are reused and code/config is updated.
#
# Usage:  ./scripts/deploy.sh
# Override defaults with env vars, e.g.:  AWS_REGION=eu-west-1 PROJECT=my-events ./scripts/deploy.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PROJECT="${PROJECT:-event-announcement}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET_NAME:-${PROJECT}-site-${ACCOUNT_ID}-${REGION}}"
TOPIC_NAME="${PROJECT}-notifications"
SUBSCRIBE_FN="${PROJECT}-subscribe"
CREATE_EVENT_FN="${PROJECT}-create-event"
SUBSCRIBE_ROLE="${PROJECT}-subscribe-lambda-role"
CREATE_EVENT_ROLE="${PROJECT}-create-event-lambda-role"
API_NAME="${PROJECT}-api"
RUNTIME="python3.13"

export AWS_REGION="$REGION" AWS_PAGER=""

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

render() {  # render <template> -> stdout, filling placeholders
  sed -e "s|__BUCKET_NAME__|$BUCKET|g" -e "s|__TOPIC_ARN__|$TOPIC_ARN|g" "$1"
}

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- 1. S3 static site
log "S3 bucket: $BUCKET"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
fi

# Static website hosting needs public reads, so lift the bucket-level public access block.
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-website --bucket "$BUCKET" \
  --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
sed "s|__BUCKET_NAME__|$BUCKET|g" "$ROOT_DIR/iam/s3-bucket-policy.json" > "$BUILD_DIR/s3-bucket-policy.json"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$BUILD_DIR/s3-bucket-policy.json"

# ---------------------------------------------------------------- 2. SNS topic
log "SNS topic: $TOPIC_NAME"
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)"  # idempotent
echo "$TOPIC_ARN"

# ---------------------------------------------------------------- 3. IAM roles
ensure_role() {  # ensure_role <role-name> <inline-policy-template>
  local role="$1" template="$2"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role" \
      --assume-role-policy-document "file://$ROOT_DIR/iam/lambda-trust-policy.json" >/dev/null
    ROLES_CREATED=1
  fi
  aws iam attach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  render "$template" > "$BUILD_DIR/$role-policy.json"
  aws iam put-role-policy --role-name "$role" --policy-name "${role}-inline" \
    --policy-document "file://$BUILD_DIR/$role-policy.json"
}

log "IAM roles"
ROLES_CREATED=0
ensure_role "$SUBSCRIBE_ROLE" "$ROOT_DIR/iam/subscribe-lambda-policy.json"
ensure_role "$CREATE_EVENT_ROLE" "$ROOT_DIR/iam/create-event-lambda-policy.json"
if [[ "$ROLES_CREATED" == 1 ]]; then
  echo "Waiting for new IAM roles to propagate..."
  sleep 15
fi

# ---------------------------------------------------------------- 4. Lambda functions
deploy_lambda() {  # deploy_lambda <function-name> <source-dir> <role-name> <env-vars>
  local fn="$1" src="$2" role="$3" env="$4"
  local zip="$BUILD_DIR/$fn.zip"
  local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role}"

  rm -f "$zip"
  (cd "$src" && zip -q -r "$zip" lambda_function.py)

  if aws lambda get-function --function-name "$fn" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$fn" --zip-file "fileb://$zip" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$fn"
    aws lambda update-function-configuration --function-name "$fn" \
      --environment "Variables={$env}" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$fn"
  else
    # Retry briefly: a freshly created role can take a few seconds to be assumable.
    local attempt
    for attempt in 1 2 3 4 5 6; do
      if aws lambda create-function --function-name "$fn" --runtime "$RUNTIME" \
           --handler lambda_function.lambda_handler --role "$role_arn" \
           --zip-file "fileb://$zip" --timeout 15 --memory-size 128 \
           --environment "Variables={$env}" >/dev/null; then
        break
      fi
      [[ $attempt == 6 ]] && { echo "Failed to create $fn" >&2; exit 1; }
      echo "Role not ready yet, retrying in 5s..."
      sleep 5
    done
    aws lambda wait function-active-v2 --function-name "$fn"
  fi
  aws lambda get-function --function-name "$fn" --query Configuration.FunctionArn --output text
}

log "Lambda: $SUBSCRIBE_FN"
SUBSCRIBE_ARN="$(deploy_lambda "$SUBSCRIBE_FN" "$ROOT_DIR/lambdas/subscribe" "$SUBSCRIBE_ROLE" \
  "SNS_TOPIC_ARN=$TOPIC_ARN")"
echo "$SUBSCRIBE_ARN"

log "Lambda: $CREATE_EVENT_FN"
CREATE_EVENT_ARN="$(deploy_lambda "$CREATE_EVENT_FN" "$ROOT_DIR/lambdas/create_event" "$CREATE_EVENT_ROLE" \
  "SNS_TOPIC_ARN=$TOPIC_ARN,BUCKET_NAME=$BUCKET,EVENTS_KEY=events.json")"
echo "$CREATE_EVENT_ARN"

# ---------------------------------------------------------------- 5. API Gateway (HTTP API)
log "API Gateway: $API_NAME"
API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)"
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
  # With CORS configured here, API Gateway answers browser preflight (OPTIONS) requests itself.
  API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
    --cors-configuration 'AllowOrigins=*,AllowMethods=POST,OPTIONS,AllowHeaders=content-type' \
    --query ApiId --output text)"
fi
API_URL="$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)"

ensure_route() {  # ensure_route <path> <function-name> <function-arn>
  local path="$1" fn="$2" fn_arn="$3"
  local route_key="POST $path"
  local integration_id route_id

  integration_id="$(aws apigatewayv2 get-integrations --api-id "$API_ID" \
    --query "Items[?IntegrationUri=='$fn_arn'].IntegrationId | [0]" --output text)"
  if [[ -z "$integration_id" || "$integration_id" == "None" ]]; then
    integration_id="$(aws apigatewayv2 create-integration --api-id "$API_ID" \
      --integration-type AWS_PROXY --integration-uri "$fn_arn" \
      --payload-format-version 2.0 --query IntegrationId --output text)"
  fi

  route_id="$(aws apigatewayv2 get-routes --api-id "$API_ID" \
    --query "Items[?RouteKey=='$route_key'].RouteId | [0]" --output text)"
  if [[ -z "$route_id" || "$route_id" == "None" ]]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$route_key" \
      --target "integrations/$integration_id" >/dev/null
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$route_id" \
      --target "integrations/$integration_id" >/dev/null
  fi

  # Allow this API (and only this route) to invoke the function.
  aws lambda remove-permission --function-name "$fn" --statement-id apigw-invoke >/dev/null 2>&1 || true
  aws lambda add-permission --function-name "$fn" --statement-id apigw-invoke \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*${path}" >/dev/null
  echo "POST $API_URL$path -> $fn"
}

ensure_route /subscribe "$SUBSCRIBE_FN" "$SUBSCRIBE_ARN"
ensure_route /create-event "$CREATE_EVENT_FN" "$CREATE_EVENT_ARN"

if ! aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name '$default' >/dev/null 2>&1; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
fi

# ---------------------------------------------------------------- 6. Upload frontend
log "Uploading frontend"
# Fill the API URL into index.html (the source file keeps its placeholder).
sed "s|__API_BASE_URL__|$API_URL|" "$ROOT_DIR/frontend/index.html" > "$BUILD_DIR/index.html"
aws s3 cp "$BUILD_DIR/index.html" "s3://$BUCKET/index.html" \
  --content-type text/html --cache-control "no-cache" --only-show-errors
aws s3 cp "$ROOT_DIR/frontend/styles.css" "s3://$BUCKET/styles.css" \
  --content-type text/css --cache-control "no-cache" --only-show-errors

# Seed events.json only once so redeploys don't wipe events created through the site.
if aws s3api head-object --bucket "$BUCKET" --key events.json >/dev/null 2>&1; then
  echo "events.json already exists in S3; left unchanged."
else
  aws s3 cp "$ROOT_DIR/frontend/events.json" "s3://$BUCKET/events.json" \
    --content-type application/json --cache-control "no-cache, no-store, must-revalidate" --only-show-errors
  echo "Seeded events.json"
fi

# Older regions use "s3-website-<region>", newer ones "s3-website.<region>".
case "$REGION" in
  us-east-1|us-west-1|us-west-2|eu-west-1|ap-southeast-1|ap-southeast-2|ap-northeast-1|sa-east-1|us-gov-west-1)
    SITE_URL="http://${BUCKET}.s3-website-${REGION}.amazonaws.com" ;;
  *)
    SITE_URL="http://${BUCKET}.s3-website.${REGION}.amazonaws.com" ;;
esac

log "Done"
cat <<EOF
Website:   $SITE_URL
API:       $API_URL
SNS topic: $TOPIC_ARN

Next: open the website, subscribe with your email, and click the confirmation link AWS sends.
Then create an event; you should receive a notification email.
EOF
