"""Unit tests for Lambda CRUD + input validation (moto DynamoDB)."""
import json
import os
import sys

import boto3
import pytest
from moto import mock_aws

# Import handler from sibling src/
SRC = os.path.join(os.path.dirname(__file__), "..", "src")
sys.path.insert(0, SRC)

TABLE = "test-items"
BUCKET = "test-bucket"


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("DYNAMODB_TABLE", TABLE)
    monkeypatch.setenv("BUCKET_NAME", BUCKET)
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")


def _event(method, path, body=None, path_params=None):
    ev = {
        "requestContext": {"http": {"method": method, "path": path}},
        "pathParameters": path_params or {},
    }
    if body is not None:
        ev["body"] = body if isinstance(body, str) else json.dumps(body)
    return ev


def _body(resp):
    return json.loads(resp["body"])


@pytest.fixture
def handler_mod(aws_env):
    import importlib
    import handler as h

    importlib.reload(h)
    return h


@pytest.fixture
def dynamo_table(aws_env, handler_mod):
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        dynamodb.create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield handler_mod


# ---------------------------------------------------------------------------
# Validation: create
# ---------------------------------------------------------------------------

def test_create_rejects_invalid_json(dynamo_table):
    resp = dynamo_table.handler(_event("POST", "/items", body="{not-json"), None)
    assert resp["statusCode"] == 400
    assert "valid JSON" in _body(resp)["error"]


def test_create_rejects_non_object(dynamo_table):
    resp = dynamo_table.handler(_event("POST", "/items", body=["a"]), None)
    assert resp["statusCode"] == 400
    assert "JSON object" in _body(resp)["error"]


def test_create_requires_name(dynamo_table):
    resp = dynamo_table.handler(_event("POST", "/items", body={"value": "x"}), None)
    assert resp["statusCode"] == 400
    assert "name" in _body(resp)["error"]


def test_create_rejects_empty_name(dynamo_table):
    resp = dynamo_table.handler(_event("POST", "/items", body={"name": "  "}), None)
    assert resp["statusCode"] == 400
    assert "non-empty" in _body(resp)["error"]


def test_create_rejects_non_string_name(dynamo_table):
    resp = dynamo_table.handler(_event("POST", "/items", body={"name": 123}), None)
    assert resp["statusCode"] == 400
    assert "string" in _body(resp)["error"]


def test_create_rejects_unknown_fields(dynamo_table):
    resp = dynamo_table.handler(
        _event("POST", "/items", body={"name": "ok", "extra": "nope"}), None
    )
    assert resp["statusCode"] == 400
    assert "Unknown field" in _body(resp)["error"]


def test_create_rejects_client_id(dynamo_table):
    resp = dynamo_table.handler(
        _event("POST", "/items", body={"id": "x", "name": "ok"}), None
    )
    assert resp["statusCode"] == 400
    assert "id" in _body(resp)["error"].lower()


def test_create_rejects_name_too_long(dynamo_table):
    resp = dynamo_table.handler(
        _event("POST", "/items", body={"name": "a" * 129}), None
    )
    assert resp["statusCode"] == 400
    assert "128" in _body(resp)["error"]


def test_create_rejects_value_too_long(dynamo_table):
    resp = dynamo_table.handler(
        _event("POST", "/items", body={"name": "ok", "value": "v" * 1025}), None
    )
    assert resp["statusCode"] == 400
    assert "1024" in _body(resp)["error"]


def test_create_rejects_non_string_value(dynamo_table):
    resp = dynamo_table.handler(
        _event("POST", "/items", body={"name": "ok", "value": 1}), None
    )
    assert resp["statusCode"] == 400
    assert "value" in _body(resp)["error"]


def test_create_strips_name_and_succeeds(dynamo_table):
    resp = dynamo_table.handler(
        _event("POST", "/items", body={"name": "  hello  ", "value": "world"}), None
    )
    assert resp["statusCode"] == 201
    data = _body(resp)
    assert data["name"] == "hello"
    assert data["value"] == "world"
    assert "id" in data


# ---------------------------------------------------------------------------
# Validation: path id
# ---------------------------------------------------------------------------

def test_get_rejects_invalid_uuid(dynamo_table):
    resp = dynamo_table.handler(
        _event("GET", "/items/not-a-uuid", path_params={"id": "not-a-uuid"}), None
    )
    assert resp["statusCode"] == 400
    assert "UUID" in _body(resp)["error"]


def test_delete_rejects_invalid_uuid(dynamo_table):
    resp = dynamo_table.handler(
        _event("DELETE", "/items/abc", path_params={"id": "abc"}), None
    )
    assert resp["statusCode"] == 400
    assert "UUID" in _body(resp)["error"]


# ---------------------------------------------------------------------------
# CRUD happy path
# ---------------------------------------------------------------------------

def test_crud_roundtrip(dynamo_table):
    create = dynamo_table.handler(
        _event("POST", "/items", body={"name": "foo", "value": "bar"}), None
    )
    assert create["statusCode"] == 201
    item_id = _body(create)["id"]

    listed = dynamo_table.handler(_event("GET", "/items"), None)
    assert listed["statusCode"] == 200
    assert any(i["id"] == item_id for i in _body(listed)["items"])

    got = dynamo_table.handler(
        _event("GET", f"/items/{item_id}", path_params={"id": item_id}), None
    )
    assert got["statusCode"] == 200
    assert _body(got)["name"] == "foo"

    deleted = dynamo_table.handler(
        _event("DELETE", f"/items/{item_id}", path_params={"id": item_id}), None
    )
    assert deleted["statusCode"] == 200
    assert _body(deleted)["deleted"] == item_id

    missing = dynamo_table.handler(
        _event("GET", f"/items/{item_id}", path_params={"id": item_id}), None
    )
    assert missing["statusCode"] == 404
