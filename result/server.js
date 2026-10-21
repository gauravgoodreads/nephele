var express = require('express'),
    path = require('path'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    http = require('http'),
    socketIo = require('socket.io');

// Nephele: the latest totals, shared by the live page, the JSON API and readiness.
var state = { votes: { a: 0, b: 0 }, lastSuccess: 0, lastError: null };
var READY_WINDOW_MS = 10000;

function collectVotesFromResult(result) {
  var votes = {a: 0, b: 0};

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

function isReady(now) {
  return state.lastSuccess > 0 && (now || Date.now()) - state.lastSuccess < READY_WINDOW_MS;
}

function createApp() {
  var app = express();

  // Nephele: probes for Kubernetes (liveness = process up, readiness = database answered recently)
  app.get('/healthz', function (req, res) {
    res.json({ status: 'ok' });
  });

  app.get('/readyz', function (req, res) {
    var ready = isReady();
    res.status(ready ? 200 : 503).json({ ready: ready, lastError: ready ? null : state.lastError });
  });

  // Nephele: the totals as JSON, for tests, scripts and monitoring
  app.get('/api/results', function (req, res) {
    var a = state.votes.a || 0, b = state.votes.b || 0;
    res.json({ a: a, b: b, total: a + b, updatedAt: state.lastSuccess ? new Date(state.lastSuccess).toISOString() : null });
  });

  app.use(cookieParser());
  app.use(express.urlencoded({ extended: false }));
  app.use(express.static(__dirname + '/views'));

  app.get('/', function (req, res) {
    res.sendFile(path.resolve(__dirname + '/views/index.html'));
  });

  return app;
}

function start() {
  var port = process.env.PORT || 4000;
  var app = createApp();
  var server = http.Server(app);
  var io = socketIo(server);

  io.on('connection', function (socket) {

    socket.emit('message', { text : 'Welcome!' });

    socket.on('subscribe', function (data) {
      socket.join(data.channel);
    });
  });

  // Nephele: the database address comes from the environment (Kubernetes Secret).
  // A pool, not one long-lived client: if the database restarts, the next query
  // simply opens a new connection instead of failing forever on a dead one.
  var pool = new Pool({
    connectionString: process.env.DATABASE_URL || 'postgres://postgres:postgres@db/postgres',
    max: 2,
    connectionTimeoutMillis: 3000
  });
  pool.on('error', function (err) {
    console.error('Idle database connection lost: ' + err.message);
  });

  var timer;
  function getVotes() {
    pool.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
      if (err) {
        if (state.lastError !== err.message) console.error("Waiting for db: " + err.message);
        state.lastError = err.message;
      } else {
        if (!state.lastSuccess || state.lastError) console.log("Connected to db");
        state.lastError = null;
        state.lastSuccess = Date.now();
        state.votes = collectVotesFromResult(result);
        io.sockets.emit("scores", JSON.stringify(state.votes));
      }

      timer = setTimeout(getVotes, 1000);
    });
  }
  getVotes();

  server.listen(port, function () {
    console.log('App running on port ' + server.address().port);
  });

  // Nephele: shut down cleanly when Kubernetes or Docker stops the container
  ['SIGTERM', 'SIGINT'].forEach(function (signal) {
    process.on(signal, function () {
      console.log('Received ' + signal + ', shutting down');
      clearTimeout(timer);
      io.close();
      server.close(function () {
        pool.end(function () { process.exit(0); });
      });
      setTimeout(function () { process.exit(0); }, 5000).unref();
    });
  });
}

if (require.main === module) {
  start();
}

module.exports = { createApp: createApp, collectVotesFromResult: collectVotesFromResult, isReady: isReady, state: state };
