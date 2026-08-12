"""
Lambda handler — REST CRUD against DynamoDB + legacy S3 demo.

Routes (all via API Gateway HTTP API proxy):
  GET  /                    → legacy: write hello.txt to S3
  POST /items               → create item  (body: {"name": "...", ...})
  GET  /items               → list all items
  GET  /items/{id}          → get one item by id
  DELETE /items/{id}        → delete one item by id
"""
import json
import logging
import os
import uuid

import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "")


def _table():
    return boto3.resource("dynamodb").Table(TABLE_NAME)


def _ok(body, status=200):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _err(message, status=400):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }


# ---------------------------------------------------------------------------
# Route handlers
# ---------------------------------------------------------------------------

def create_item(event):
    raw = event.get("body") or "{}"
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return _err("Request body must be valid JSON")

    if not isinstance(data, dict):
        return _err("Request body must be a JSON object")

    item_id = str(uuid.uuid4())
    item = {"id": item_id, **data}

    logger.info("create_item id=%s", item_id)
    _table().put_item(Item=item)
    return _ok(item, status=201)


def list_items(_event):
    logger.info("list_items")
    result = _table().scan()
    return _ok({"items": result.get("Items", [])})


def get_item(event):
    item_id = (event.get("pathParameters") or {}).get("id")
    if not item_id:
        return _err("Missing path parameter: id")

    logger.info("get_item id=%s", item_id)
    result = _table().get_item(Key={"id": item_id})
    item = result.get("Item")
    if item is None:
        return _err(f"Item '{item_id}' not found", status=404)
    return _ok(item)


def delete_item(event):
    item_id = (event.get("pathParameters") or {}).get("id")
    if not item_id:
        return _err("Missing path parameter: id")

    logger.info("delete_item id=%s", item_id)
    _table().delete_item(Key={"id": item_id})
    return _ok({"deleted": item_id})


def legacy_s3(_event):
    """Original demo: write hello.txt to S3."""
    key = "hello.txt"
    boto3.client("s3").put_object(Bucket=BUCKET_NAME, Key=key, Body=b"hello from lambda")
    logger.info("legacy_s3 bucket=%s key=%s", BUCKET_NAME, key)
    return _ok({"ok": True, "message": "wrote object to S3", "bucket": BUCKET_NAME, "key": key})


# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------

def handler(event, context):
    method = (event.get("requestContext") or {}).get("http", {}).get("method", "GET")
    path = (event.get("requestContext") or {}).get("http", {}).get("path", "/")

    logger.info("request method=%s path=%s", method, path)

    # Strip trailing slash for matching
    path = path.rstrip("/") or "/"

    if path == "/" and method == "GET":
        return legacy_s3(event)

    if path == "/items":
        if method == "POST":
            return create_item(event)
        if method == "GET":
            return list_items(event)

    if path.startswith("/items/"):
        if method == "GET":
            return get_item(event)
        if method == "DELETE":
            return delete_item(event)

    return _err(f"Route not found: {method} {path}", status=404)
