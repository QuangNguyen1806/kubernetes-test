import json
import logging
import os
import time
import uuid

import redis
from fastapi import FastAPI, Request
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","app":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger(os.getenv("APP_NAME", "demo-api"))

app = FastAPI()

APP_NAME = os.getenv("APP_NAME", "demo-api")
MESSAGE = os.getenv("MESSAGE", "default")
API_KEY = os.getenv("API_KEY", "")

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", "")
REDIS_KEY = os.getenv("REDIS_KEY", "items")

r = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    password=REDIS_PASSWORD or None,
    decode_responses=True,
)

# Exposes /metrics for Prometheus ServiceMonitors.
Instrumentator(
    should_group_status_codes=True,
    should_ignore_untemplated=True,
    excluded_handlers=["/metrics"],
).instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


@app.middleware("http")
async def access_log(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = (time.perf_counter() - start) * 1000
    log.info(
        "method=%s path=%s status=%s duration_ms=%.1f",
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
    )
    return response


class Item(BaseModel):
    name: str
    value: str


@app.get("/")
def root():
    return {
        "app": APP_NAME,
        "configmap": {"MESSAGE": MESSAGE},
        "secret": {"API_KEY": f"{API_KEY[:4]}****" if API_KEY else None},
    }


@app.post("/items")
def create_item(item: Item):
    item_id = str(uuid.uuid4())
    r.hset(REDIS_KEY, item_id, json.dumps(item.model_dump()))
    log.info("created item id=%s name=%s", item_id, item.name)
    return {"id": item_id, **item.model_dump()}


@app.get("/items")
def list_items():
    items = r.hgetall(REDIS_KEY)
    log.info("listed items count=%s", len(items))
    return [{"id": k, **json.loads(v)} for k, v in items.items()]
