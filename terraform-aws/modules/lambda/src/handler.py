import json
import os

import boto3


def handler(event, context):
    """GET / → write hello.txt to S3 and return JSON."""
    bucket = os.environ["BUCKET_NAME"]
    key = "hello.txt"
    body = b"hello from lambda"

    boto3.client("s3").put_object(Bucket=bucket, Key=key, Body=body)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "ok": True,
                "message": "wrote object to S3",
                "bucket": bucket,
                "key": key,
            }
        ),
    }
