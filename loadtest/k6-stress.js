// Stress test: ramps to 150 simultaneous voters to find where the platform
// stops scaling (6 vote pods at most, each capped at 0.3 CPU).
//
//   k6 run loadtest/k6-stress.js
//
// No pass/fail thresholds on latency: the point is to measure the limit.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://vote.localtest.me:8888';

export const options = {
  stages: [
    { duration: '1m', target: 50 },
    { duration: '2m', target: 150 },
    { duration: '1m', target: 150 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const option = Math.random() < 0.5 ? 'a' : 'b';
  const res = http.post(`${BASE_URL}/`, { vote: option });
  check(res, { 'vote accepted': (r) => r.status === 200 });
  sleep(0.5);
}
