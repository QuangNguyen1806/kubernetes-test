"""
Lambda handler — REST CRUD against DynamoDB + legacy S3 demo.

Routes (all via API Gateway HTTP API proxy):
  GET  /                    → legacy: write hello.txt to S3
  POST /items               → create item  (body: {"name": "...", "value": "..."})
  GET  /items               → list all items
  GET  /items/{id}          → get one item by id
  DELETE /items/{id}        → delete one item by id
"""
import json
import logging
import os
import re
import uuid

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "")

# Create-body rules
ALLOWED_FIELDS = frozenset({"name", "value"})
NAME_MAX_LEN = 128
VALUE_MAX_LEN = 1024
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


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


def _parse_json_object(raw):
    """Return (data, None) or (None, error_response)."""
    try:
        data = json.loads(raw if raw is not None else "{}")
    except json.JSONDecodeError:
        return None, _err("Request body must be valid JSON")

    if not isinstance(data, dict):
        return None, _err("Request body must be a JSON object")

    return data, None


def _validate_create_body(data):
    """
    Validate POST /items body.

    Allowed fields: name (required string), value (optional string).
    Rejects unknown fields and client-supplied id.
    Returns (cleaned_dict, None) or (None, error_response).
    """
    if "id" in data:
        return None, _err("Do not send 'id'; it is assigned by the server")

    unknown = sorted(set(data.keys()) - ALLOWED_FIELDS)
    if unknown:
        return None, _err(
            f"Unknown field(s): {', '.join(unknown)}. "
            f"Allowed: {', '.join(sorted(ALLOWED_FIELDS))}"
        )

    if "name" not in data:
        return None, _err("Missing required field: name")

    name = data["name"]
    if not isinstance(name, str):
        return None, _err("Field 'name' must be a string")
    name = name.strip()
    if not name:
        return None, _err("Field 'name' must be a non-empty string")
    if len(name) > NAME_MAX_LEN:
        return None, _err(f"Field 'name' must be at most {NAME_MAX_LEN} characters")

    cleaned = {"name": name}

    if "value" in data:
        value = data["value"]
        if not isinstance(value, str):
            return None, _err("Field 'value' must be a string")
        if len(value) > VALUE_MAX_LEN:
            return None, _err(f"Field 'value' must be at most {VALUE_MAX_LEN} characters")
        cleaned["value"] = value

    return cleaned, None


def _validate_item_id(item_id):
    """Return (id, None) or (None, error_response)."""
    if not item_id:
        return None, _err("Missing path parameter: id")
    if not isinstance(item_id, str) or not UUID_RE.match(item_id):
        return None, _err("Path parameter 'id' must be a valid UUID")
    return item_id, None


# ---------------------------------------------------------------------------
# Route handlers
# ---------------------------------------------------------------------------

def create_item(event):
    data, err = _parse_json_object(event.get("body"))
    if err:
        return err

    cleaned, err = _validate_create_body(data)
    if err:
        return err

    item_id = str(uuid.uuid4())
    item = {"id": item_id, **cleaned}

    logger.info("create_item id=%s", item_id)
    _table().put_item(Item=item)
    return _ok(item, status=201)


def list_items(_event):
    logger.info("list_items")
    result = _table().scan()
    return _ok({"items": result.get("Items", [])})


def get_item(event):
    item_id, err = _validate_item_id((event.get("pathParameters") or {}).get("id"))
    if err:
        return err

    logger.info("get_item id=%s", item_id)
    result = _table().get_item(Key={"id": item_id})
    item = result.get("Item")
    if item is None:
        return _err(f"Item '{item_id}' not found", status=404)
    return _ok(item)


def delete_item(event):
    item_id, err = _validate_item_id((event.get("pathParameters") or {}).get("id"))
    if err:
        return err

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
