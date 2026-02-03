# PacerPro Coding Test

EC2 generates slow `/api/data` response logs, ships them to Sumo Logic via HTTP Source. A Logs monitor fires when more than 5 entries exceed 3 seconds within a 10-minute window. The webhook hits API Gateway, which triggers a Lambda that reboots the EC2 instance and sends an SNS email notification.

---

## Part 1 — Sumo Logic Query & Alert

Query is in `sumo_logic_query.txt`. It filters on `_sourceCategory=api/logs`, parses out `endpoint` and `response_time`, keeps only `/api/data` responses over 3000ms, and counts them as `slow_hits`. The monitor's detection window handles the 10-minute grouping — no `timeslice` needed in the query itself. Trigger is set on `slow_hits > 5`. Webhook notification points to the API Gateway endpoint.

## Part 2 — Lambda Function

`lambda_function/handler.py`. Reads `EC2_INSTANCE_ID` and `SNS_TOPIC_ARN` from environment variables (set by Terraform). Checks instance state before rebooting — skips if not running. Logs everything to CloudWatch. Sends SNS on both success and failure via a shared `send_notification` helper.

## Part 3 — Terraform

`terraform/main.tf` deploys everything: EC2 instance with a user_data script that runs a systemd service to generate and ship slow API logs, security group, SNS topic with email subscription, IAM role with a least-privilege policy, the Lambda function itself, and an API Gateway HTTP API wired to it. Outputs the webhook URL, EC2 instance ID, and SNS topic ARN.

---

## Deploying

Needs Terraform >= 1.0, AWS CLI configured, and a Sumo Logic account.

First, create a Hosted Collector in Sumo Logic with an HTTP Source. Set the source category to `api/logs`. Copy the HTTP Source URL — you'll pass it to Terraform.

```bash
cd terraform
terraform init
terraform apply \
  -var="email=your@email.com" \
  -var="vpc_id=your-vpc-id" \
  -var="subnet_id=your-public-subnet-id" \
  -var="sumo_http_url=https://endpoint.collection.sumologic.com/receiver/v1/http/..."
```

Confirm the SNS subscription email AWS sends you. Then create the Logs Monitor in Sumo Logic using the query from `sumo_logic_query.txt` — trigger field `slow_hits`, threshold greater than 5, detection window 10 minutes. Add a Webhook notification with the URL from `terraform output webhook_url`.

The EC2 user_data starts shipping logs as soon as the instance boots. The monitor should fire within a few minutes.

---

## Assumptions

**API Gateway instead of Lambda Function URL.** Sumo Logic's webhook calls had issues with Lambda Function URLs during testing. API Gateway HTTP API is the standard pattern for external webhook ingress and worked without friction. The trigger mechanism is functionally identical — Sumo fires a POST, Lambda runs.

**Execution order: Part 3 → Part 2 → Part 1.** Terraform had to deploy first. Lambda needed the EC2 instance ID and SNS topic ARN (Terraform outputs) before it could be tested. Sumo Logic needed the working webhook URL before the monitor could be wired up.

**SSH open in the security group.** Port 22 is open to 0.0.0.0/0 so EC2 Instance Connect works for verification. Lock this down in production.

**AMI is hardcoded.** `ami-0c02fb55956c7d316` — Amazon Linux 2 in us-east-1. A `data` source lookup is the cleaner approach but adds no value for this test.

**`ec2:DescribeInstances` is scoped to `*`.** AWS doesn't support resource-level permissions on that action. It's the only wildcard in the policy. `RebootInstances` is scoped to the specific instance ARN, `sns:Publish` to the specific topic ARN, and CloudWatch log permissions are scoped to the `/aws/lambda/api-monitor-*` prefix.

**Sumo webhook payload is empty.** The Lambda doesn't use anything from Sumo's alert payload. Instance ID and SNS topic ARN come from environment variables. An empty `{}` payload is all that's needed to trigger execution.
