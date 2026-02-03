

from datetime import datetime, timezone
import boto3
import os
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2')
sns = boto3.client('sns')

def send_notification(status,details):
    sns_topic = os.environ.get('SNS_TOPIC_ARN')
    instance_id = os.environ.get('Ec2_INSTANCE_ID')

    try:
        sns.publish(
            TopicArn=sns_topic, 
            Subject=f"EC2 Auto-Remediation: {status}",
            Message=f"Instance: {instance_id}\nStatus: {status}\nDetails:{details}"
        )
        logger.info(f"SNS notification sent {status}")

    except Exception as e:
        logger.error(f"Failed to send SNS notification: {e}")

def lambda_handler(event, context) :
    logger.info(f"Received event: {json.dumps(event)}")
    
    instance_id = os.environ.get('EC2_INSTANCE_ID')
    sns_topic=os.environ.get('SNS_TOPIC_ARN')

    if not instance_id or not sns_topic:
        logger.error("Missing required environment variables")
        return {'statusCode': 500, 'body': 'Configuration error'}
    
    try:
        # Check instance state first
        resp=ec2.describe_instances(InstanceIds=[instance_id])
        state = resp['Reservations'][0]['Instances'][0]['State']['Name']
        logger.info(f"Instance {instance_id} state: {state}")

        if state !='running':
            msg = f"Instance not running, current state: {state}"
            logger.warning(msg)
            return {'statusCode': 200, 'body':msg}

        # reboot the instance
        ec2.reboot_instances(InstanceIds=[instance_id])
        logger.info(f"Rebooted insitiated for {instance_id}")

        # send success notification
        send_notification("SUCCESS", f"Rebooted instance {instance_id}")
        return {'statusCode': 200, 'body': 'Reboot Initiated'}

    except Exception as e:
        logger.error(f"remediation failed: {e}")
        send_notification("FAILED", str(e))
        return {'statusCode': 500, 'body': str(e)}
