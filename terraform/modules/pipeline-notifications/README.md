# Pipeline Notifications Module

Automated Slack notifications for AWS CodePipeline failures using EventBridge and Lambda.

## Architecture

```text
CodePipeline (FAILED) → EventBridge Rule → Lambda Function → SSM Parameter Store → Slack Webhook
```

## Usage

```hcl
module "pipeline_notifications" {
  source = "../pipeline-notifications"

  slack_webhook_ssm_param = "/rosa-regional/slack/webhook-url"
  name_prefix             = "my-project"
  region                  = "us-east-1"
}
```

## Inputs

| Name                      | Description                               | Type   | Required | Default |
| ------------------------- | ----------------------------------------- | ------ | -------- | ------- |
| `slack_webhook_ssm_param` | SSM Parameter path containing webhook URL | string | Yes      | -       |
| `name_prefix`             | Prefix for resource names                 | string | No       | ""      |
| `region`                  | AWS Region                                | string | Yes      | -       |

## Setup

### 1. Store Slack Webhook in SSM Parameter Store

```bash
aws ssm put-parameter \
  --name "/rosa-regional/slack/webhook-url" \
  --value "https://hooks.slack.com/services/T00000000/B00000000/XXXX" \
  --type "SecureString" \
  --description "Slack webhook for pipeline failure notifications"
```

### 2. Get Slack Webhook URL

1. Go to [Slack API: Incoming Webhooks](https://api.slack.com/messaging/webhooks)
2. Create or use existing app → Enable "Incoming Webhooks"
3. Add webhook to workspace and select channel
4. Copy webhook URL to use in SSM parameter above

## Notification Format

Messages include:

- Pipeline name and failure status
- Execution ID, region, account, timestamp
- Direct link to AWS Console

## Testing

1. Deploy module with webhook URL
2. Trigger a pipeline failure
3. Check Slack for notification
4. View logs: `aws logs tail /aws/lambda/{name_prefix}pipeline-failure-notifier --follow`

## Troubleshooting

- Verify webhook URL is active
- Check Lambda logs for errors
- Ensure pipeline actually failed
- Confirm EventBridge rule is enabled

## Security Features

- **SSM Parameter Store**: Webhook URL stored securely, fetched at runtime
- **KMS Encryption**: SecureString parameters encrypted with KMS
- **Least Privilege IAM**: Lambda has scoped access to specific SSM parameter
- **No Secrets in Environment**: Lambda environment variables contain only parameter path

## Notes

- Monitors pipelines in deployed region and account only
- Currently detects `FAILED` state only
- Lambda fetches webhook URL from SSM at runtime (not stored in environment)
