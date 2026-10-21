from flask import Flask, Response, render_template, request, make_response, g
from prometheus_client import CollectorRegistry, Gauge, generate_latest, CONTENT_TYPE_LATEST
from redis import Redis
import os
import socket
import random
import json
import logging

option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
# Nephele: connection settings come from the environment (Kubernetes ConfigMap/Secret)
redis_host = os.getenv('REDIS_HOST', "redis")
redis_port = int(os.getenv('REDIS_PORT', "6379"))
redis_password = os.getenv('REDIS_PASSWORD') or None
hostname = socket.gethostname()

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

def get_redis():
    if not hasattr(g, 'redis'):
        # Short timeouts: a slow or restarting Redis must fail a request quickly,
        # not tie up a web worker (and with it the health checks) for seconds.
        g.redis = Redis(host=redis_host, port=redis_port, password=redis_password, db=0,
                        socket_timeout=2, socket_connect_timeout=1)
    return g.redis

@app.route("/", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    vote = None

    if request.method == 'POST':
        redis = get_redis()
        vote = request.form['vote']
        if vote not in ('a', 'b'):
            return make_response("Unknown option", 400)
        app.logger.info('Received vote for %s', vote)
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        redis.rpush('votes', data)
        # Nephele: shared counter, so every pod reports the same metric
        redis.incr('nephele:votes_received:' + vote)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp


@app.route("/healthz")
def healthz():
    """Liveness probe: the web process is running."""
    return {"status": "ok"}


@app.route("/readyz")
def readyz():
    """Readiness probe: Redis answers, so votes can be queued."""
    try:
        get_redis().ping()
        return {"ready": True}
    except Exception as exc:
        return {"ready": False, "error": type(exc).__name__}, 503


@app.route("/metrics")
def metrics():
    """Prometheus metrics read from Redis, so they are the same whichever pod answers."""
    registry = CollectorRegistry()
    received = Gauge('nephele_votes_received', 'Votes accepted by the vote service',
                     ['option'], registry=registry)
    depth = Gauge('nephele_queue_depth', 'Votes waiting on the Redis queue for the worker',
                  registry=registry)
    in_flight = Gauge('nephele_votes_in_flight', 'Votes taken by a worker but not yet saved',
                      registry=registry)
    saved = Gauge('nephele_votes_saved', 'Votes saved to PostgreSQL by the workers',
                  registry=registry)
    redis = get_redis()
    for option in ('a', 'b'):
        received.labels(option).set(int(redis.get('nephele:votes_received:' + option) or 0))
    depth.set(redis.llen('votes'))
    in_flight.set(sum(redis.llen(key) for key in redis.scan_iter('votes:processing:*', count=100)))
    saved.set(int(redis.get('nephele:votes_saved') or 0))
    return Response(generate_latest(registry), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80, debug=True, threaded=True)
