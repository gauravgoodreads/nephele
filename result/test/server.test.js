// Unit tests for the result service, using Node's built-in test runner (no database needed).
//   npm test
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const { createApp, collectVotesFromResult, isReady, state } = require('../server');

function get(server, path) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    http.get({ host: '127.0.0.1', port, path }, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(body) }));
    }).on('error', reject);
  });
}

function listen() {
  return new Promise((resolve) => {
    const server = http.createServer(createApp());
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

test('counts votes per option from the database rows', () => {
  const votes = collectVotesFromResult({ rows: [{ vote: 'a', count: '7' }, { vote: 'b', count: '3' }] });
  assert.deepStrictEqual(votes, { a: 7, b: 3 });
});

test('an option with no votes counts as zero', () => {
  assert.deepStrictEqual(collectVotesFromResult({ rows: [{ vote: 'b', count: '2' }] }), { a: 0, b: 2 });
  assert.deepStrictEqual(collectVotesFromResult({ rows: [] }), { a: 0, b: 0 });
});

test('ready only after a recent successful database read', () => {
  const now = Date.now();
  state.lastSuccess = 0;
  assert.strictEqual(isReady(now), false);
  state.lastSuccess = now - 2000;
  assert.strictEqual(isReady(now), true);
  state.lastSuccess = now - 60000;
  assert.strictEqual(isReady(now), false);
});

test('health, readiness and results endpoints', async () => {
  const server = await listen();
  try {
    state.lastSuccess = 0;
    state.lastError = 'connect ECONNREFUSED';
    assert.deepStrictEqual((await get(server, '/healthz')).body, { status: 'ok' });

    const notReady = await get(server, '/readyz');
    assert.strictEqual(notReady.status, 503);
    assert.strictEqual(notReady.body.lastError, 'connect ECONNREFUSED');

    state.votes = { a: 12, b: 8 };
    state.lastSuccess = Date.now();
    state.lastError = null;
    assert.strictEqual((await get(server, '/readyz')).status, 200);
    const results = await get(server, '/api/results');
    assert.strictEqual(results.status, 200);
    assert.strictEqual(results.body.a, 12);
    assert.strictEqual(results.body.b, 8);
    assert.strictEqual(results.body.total, 20);
  } finally {
    server.close();
  }
});
