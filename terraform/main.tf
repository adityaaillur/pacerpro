
terraform {
    required_version = ">= 1.0"
    required_providers {
        aws = {
            source = "hashicorp/aws", version = "~>5.0"
        }
        archive = {source = "hashicorp/archive", version = "~>2.0" }
    }
}

provider "aws" {
    region = var.region
}

# vars

variable "region" { default = "us-east-1"}
variable "email" {description = "Notification Email"}
variable "vpc_id" {}
variable "subnet_id" {}
variable "sumo_http_url" {description = "Sumo HTTP Source url"}

variable "ami_id" {
    # ami for us-east-1
    default = "ami-0b72821e2f351e396"
}

# ec1 instance

resource "aws_security_group" "web" {
    name = "api-monitor-web-sg"
    description = "web server"
    vpc_id = var.vpc_id

    #HTTP
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0.0/0"]
    }
    #HTTPS
    ingress {
        from_port = 443
        to_port = 443
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    #SSH
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_instance" "web" {
    ami = var.ami_id
    instance_type "t3.micro"
    subnet_id = var.subnet_id
    vpc_security_group_ids = [aws_security_group.web.id]
    tags = {Name = "api-monitor-web"}

    user_data = <<-EOF
#!/bin/bash
set -e

cat >/usr/local/bin/gen_api_logs.sh <<SH
#!/bin/bash
set -e
while true; do
 for i in {1..6}; do
   line="\$(date -u +%FT%TZ) endpoint=\"/api/data\" response_time=3501 status=200"
   curl -sS -X POST "${var.sumo_http_url}" \
     -H "Content-Type: text/plain" \
     -H "X-Sumo-Categroy: api/logs" \
     --data "\$line" >/dev/null
  done
  sleep 600
done
SH

chmod +X /usr/local/bin/gen_api_logs.sh
cat >/etc/systemd/system/gen-api-logs.service <<'UNIT'
[Unit]
Description=Generate /api/data slow logs and ship to Sumo
After=network.target

[service]
ExecStart=/usr/loal/bin/gen_api_logs.sh
Restart-always

[Install]
WantedBy=multi-user.target
systemctl daemon-reload
systemctl enable --now gen-api-logs
EOF

}

# SNS Topic

resource "aws_sns_topic" "alerts" {
    name = "api-monitor-alerts"
}

resource "aws_sns_topic_subscription" "email" {
    topic_arn = aws_sns_topic.alerts.arn
    protocol = "email"
    endpoint = var.email
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "lambda" {
    name = "api-monitor-iam-role"

    assume_role_policy = jsonencode ({
        Version = "2012-10-17"
        Statement =[{
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = { Service = "lambda.amazonaws.com"}
        }]
    })
}
resource "aws_iam_role_policy" "lambda" {
    name = "api-monitor-lambda-policy"
    role = aws_iam_role.lambda.id

    Policy = jsonencode({
        Version ="2012-10-17"
        Statement =[
             {
                # cloudwatch logs
                Effect = "Allow"
                Action = ["logs:CreateLogGroup","logs:CreateLogStream","Logs:PutLogEvents"]
                Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/api-monitor-*"
            },
            {
                # we need describe for all the EC2 instances
                Effect = "Allow"
                Action = "ec2:DescribeInstances"
                Resource = "*"
            },
            {
                # reboot only teh specific instance
                Effect = "Allow"
                Action = "ec2:RebootInstances"
                Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.web.id}"
            },
            {
                # sns
                Effect = "Allow"
                Action = "sns:Publish"
                Resource = aws_sns_topic.alerts.arn
            }
            
        ]
    })
}

data "archive_file "lambda {
    type = "zip"
    source_dir = "${path.module}/../lambda_function"
    output_path = "${path.module}/lambda.zip"
    excludes = ["test_event.json"]
}

resource "aws_lambda_function" "remediation" {
    filename = data.archive_file.lambda.output_path
    function_name = "api-monitor-remediation"
    role = aws_iam_role.lambda.arn
    handler = "handler.lambda_handler"
    runtime = "python3.11"
    timeout = 30
    source_code_hash = data.archive_file.lambda.output_base64sha256

    environment {
        variables ={
            EC2_INSTANCE_ID = aws_instance.id
            SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
        }
    }
}

# HTTP API Gateway

resource "aws_apigatewayv2_api" "webhook" {
    name = "api-monitor-webhook"
    protocol_type ="HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
    api_id = aws_apigatewayv2_api.webhook.id
    integration_type = "AWS_PROXY"
    integration_uri = aws_lambda_function.remediation.invoke_arn
    payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post" {
    api_id = aws_apigatewayv2_api.webhook.id
    route_key = "POST /"
    target = "integration/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
    api_id = aws_apigatewayv2_api.webhook.id
    name = "$default"
    auto_deploy = true
}

# permission 

resource "aws_lamda_permission" "apigw" {
    statement_id = "AllowAPIGateway"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.remediation.function_name
    principal = "apigateway.amazonaws.com"
    source_arn = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}

# Outputs

output "ec2_instance_id" { value = aws_instance.web.id}
output "webhook_url" { value = aws_apigateway_api.webhook.api_endpoint }
output "sns_topic_arn" { value = aws_sns_topic.alerts.arn}