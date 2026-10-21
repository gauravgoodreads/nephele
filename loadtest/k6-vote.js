// Load test: many people voting at once.
// Shows the autoscaler adding vote pods and the queue being drained by the worker.
//
//   k6 run loadtest/k6-vote.js
//   k6 run -e BASE_URL=http://localhost:8080 loadtest/k6-vote.js   (Docker Compose)
//
// Watch it scale in another terminal:  kubectl -n nephele get hpa,pods -w

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://vote.localtest.me:8888';

export const options = {
  stages: [
    { duration: '30s', target: 20 },
    { duration: '2m', target: 60 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const option = Math.random() < 0.5 ? 'a' : 'b';
  const res = http.post(`${BASE_URL}/`, { vote: option });
  check(res, { 'vote accepted': (r) => r.status === 200 });
  sleep(0.5);
}
