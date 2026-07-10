import json
import os
import uuid

import redis
from fastapi import FastAPI
from pydantic import BaseModel

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
    return {"id": item_id, **item.model_dump()}


@app.get("/items")
def list_items():
    items = r.hgetall(REDIS_KEY)
    return [{"id": k, **json.loads(v)} for k, v in items.items()]
