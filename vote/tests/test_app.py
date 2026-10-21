"""Unit tests for the vote service. fakeredis stands in for Redis, so no containers are needed."""

import json

import fakeredis
import pytest

import app as vote_app


@pytest.fixture
def client(monkeypatch):
    fake = fakeredis.FakeRedis()
    monkeypatch.setattr(vote_app, "get_redis", lambda: fake)
    vote_app.app.config["TESTING"] = True
    with vote_app.app.test_client() as c:
        c.redis = fake
        yield c


def test_home_page_shows_both_options(client):
    res = client.get("/")
    assert res.status_code == 200
    assert b"Cats" in res.data and b"Dogs" in res.data
    assert "voter_id" in res.headers.get("Set-Cookie", "")


def test_vote_is_queued_for_the_worker(client):
    res = client.post("/", data={"vote": "a"})
    assert res.status_code == 200
    queued = [json.loads(x) for x in client.redis.lrange("votes", 0, -1)]
    assert len(queued) == 1 and queued[0]["vote"] == "a"


def test_unknown_option_is_rejected(client):
    assert client.post("/", data={"vote": "z"}).status_code == 400
    assert client.redis.llen("votes") == 0


def test_health_and_readiness(client):
    assert client.get("/healthz").get_json() == {"status": "ok"}
    assert client.get("/readyz").get_json() == {"ready": True}


def test_metrics_report_votes_and_queue_depth(client):
    client.post("/", data={"vote": "a"})
    client.post("/", data={"vote": "b"})
    client.post("/", data={"vote": "a"})
    text = client.get("/metrics").get_data(as_text=True)
    assert 'nephele_votes_received{option="a"} 2.0' in text
    assert 'nephele_votes_received{option="b"} 1.0' in text
    assert "nephele_queue_depth 3.0" in text
