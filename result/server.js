var express = require('express'),
    path = require('path'),
    async = require('async'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    app = express(),
    server = require('http').Server(app),
    io = require('socket.io')(server);

var port = process.env.PORT || 4000;

io.on('connection', function (socket) {

  socket.emit('message', { text : 'Welcome!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// Nephele: the database address comes from the environment (Kubernetes Secret)
var pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgres://postgres:postgres@db/postgres'
});
var dbReady = false;

async.retry(
  {times: 1000, interval: 1000},
  function(callback) {
    pool.connect(function(err, client, done) {
      if (err) {
        console.error("Waiting for db");
      }
      callback(err, client);
    });
  },
  function(err, client) {
    if (err) {
      return console.error("Giving up");
    }
    console.log("Connected to db");
    dbReady = true;
    getVotes(client);
  }
);

function getVotes(client) {
  client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
    if (err) {
      console.error("Error performing query: " + err);
    } else {
      var votes = collectVotesFromResult(result);
      io.sockets.emit("scores", JSON.stringify(votes));
    }

    setTimeout(function() {getVotes(client) }, 1000);
  });
}

function collectVotesFromResult(result) {
  var votes = {a: 0, b: 0};

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

// Nephele: probes for Kubernetes (liveness = process up, readiness = database connected)
app.get('/healthz', function (req, res) {
  res.json({ status: 'ok' });
});

app.get('/readyz', function (req, res) {
  res.status(dbReady ? 200 : 503).json({ ready: dbReady });
});

app.use(cookieParser());
app.use(express.urlencoded());
app.use(express.static(__dirname + '/views'));

app.get('/', function (req, res) {
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

server.listen(port, function () {
  var port = server.address().port;
  console.log('App running on port ' + port);
});

// Nephele: shut down cleanly when Kubernetes or Docker stops the container
['SIGTERM', 'SIGINT'].forEach(function (signal) {
  process.on(signal, function () {
    console.log('Received ' + signal + ', shutting down');
    io.close();
    server.close(function () {
      pool.end(function () { process.exit(0); });
    });
    setTimeout(function () { process.exit(0); }, 5000).unref();
  });
});
