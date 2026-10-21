using System;
using System.Data.Common;
using System.IO;
using System.Linq;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;

namespace Worker
{
    // Nephele: a reliable queue consumer.
    //
    // The original worker popped a vote off Redis and then saved it, so a crash
    // between the two lost the vote, and a vote that arrived while the database
    // was reconnecting was dropped. Now each vote is MOVED to this worker's own
    // "processing" list, saved, and only then removed. A worker that starts (or
    // checks every 30 seconds) puts back any votes left in the processing list of
    // a worker that has died. Saving is an upsert, so a vote delivered twice is
    // still counted once.
    public class Program
    {
        const string Queue = "votes";
        const string ProcessingPrefix = "votes:processing:";
        const string AlivePrefix = "worker:alive:";
        const string SavedCounter = "nephele:votes_saved";
        const string HeartbeatFile = "/tmp/worker-heartbeat";

        static readonly CancellationTokenSource Stop = new CancellationTokenSource();
        static readonly ManualResetEventSlim Stopped = new ManualResetEventSlim(false);

        public static int Main(string[] args)
        {
            // Kubernetes sends SIGTERM before stopping a pod: finish the current vote, then exit.
            AppDomain.CurrentDomain.ProcessExit += (_, _) => { Stop.Cancel(); Stopped.Wait(TimeSpan.FromSeconds(20)); };
            Console.CancelKeyPress += (_, e) => { e.Cancel = true; Stop.Cancel(); };
            try
            {
                return Run();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
            finally
            {
                Stopped.Set();
            }
        }

        static int Run()
        {
            // Connection settings come from the environment (Kubernetes ConfigMap/Secret)
            var dbConnectionString = string.Format(
                "Server={0};Username={1};Password={2};Database={3};Timeout=5;Keepalive=30;",
                Env("DB_HOST", "db"), Env("DB_USER", "postgres"),
                Env("DB_PASSWORD", "postgres"), Env("DB_NAME", "postgres"));
            var redisAddress = $"{Env("REDIS_HOST", "redis")}:{Env("REDIS_PORT", "6379")}";
            var workerName = Env("HOSTNAME", Environment.MachineName);
            var processing = ProcessingPrefix + workerName;

            var redisConn = ConnectionMultiplexer.Connect($"{redisAddress},abortConnect=false,connectRetry=10");
            var redis = redisConn.GetDatabase();
            while (!redisConn.IsConnected && !Stop.IsCancellationRequested)
            {
                Console.Error.WriteLine("Waiting for redis");
                TouchHeartbeat(); // waiting is healthy: keep the liveness probe satisfied
                Sleep(1000);
            }
            var pgsql = OpenDbConnection(dbConnectionString);
            if (pgsql == null) return 0;

            Beat(redis, workerName);
            RecoverOrphans(redisConn, redis, workerName);
            Console.WriteLine($"Worker {workerName} ready");

            var definition = new { vote = "", voter_id = "" };
            var lastBeat = DateTime.UtcNow;
            var lastRecovery = DateTime.UtcNow;

            while (!Stop.IsCancellationRequested)
            {
                var now = DateTime.UtcNow;
                if ((now - lastBeat).TotalSeconds >= 5)
                {
                    lastBeat = now;
                    Beat(redis, workerName);
                }
                if ((now - lastRecovery).TotalSeconds >= 30)
                {
                    lastRecovery = now;
                    RecoverOrphans(redisConn, redis, workerName);
                }

                RedisValue item;
                try
                {
                    item = redis.ListMove(Queue, processing, ListSide.Left, ListSide.Right);
                }
                catch (RedisException ex)
                {
                    Console.Error.WriteLine($"Redis unavailable: {ex.Message}");
                    Sleep(1000);
                    continue;
                }

                if (item.IsNull)
                {
                    Sleep(100); // queue empty: wait a little before looking again
                    continue;
                }

                var vote = JsonConvert.DeserializeAnonymousType((string)item, definition);
                try
                {
                    if (pgsql.State != System.Data.ConnectionState.Open)
                    {
                        pgsql.Dispose();
                        pgsql = OpenDbConnection(dbConnectionString);
                        if (pgsql == null) break;
                    }
                    SaveVote(pgsql, vote.voter_id, vote.vote);
                    redis.ListRemove(processing, item, 1);
                    redis.StringIncrement(SavedCounter);
                    Console.WriteLine($"Processing vote for '{vote.vote}' by '{vote.voter_id}'");
                }
                catch (RedisException ex)
                {
                    // Saved, but not yet removed from the processing list: it will be
                    // delivered again later, and the upsert makes that harmless.
                    Console.Error.WriteLine($"Redis unavailable after saving: {ex.Message}");
                    Sleep(1000);
                }
                catch (Exception ex) when (ex is DbException || ex is IOException ||
                                           ex is InvalidOperationException || ex is TimeoutException)
                {
                    Console.Error.WriteLine($"Database unavailable ({ex.GetType().Name}); returning the vote to the queue");
                    TryRedis(() =>
                    {
                        redis.ListLeftPush(Queue, item);
                        redis.ListRemove(processing, item, 1);
                    });
                    try { pgsql.Dispose(); } catch { }
                    pgsql = OpenDbConnection(dbConnectionString);
                    if (pgsql == null) break;
                }
            }

            Console.WriteLine("Shutdown requested: current vote finished, exiting");
            TryRedis(() => redis.KeyDelete(AlivePrefix + workerName));
            return 0;
        }

        // Liveness: a file the Kubernetes probe checks, and a short-lived key other
        // workers check before taking over this worker's unfinished votes.
        static void Beat(IDatabase redis, string workerName)
        {
            TouchHeartbeat();
            TryRedis(() => redis.StringSet(AlivePrefix + workerName, "1", TimeSpan.FromSeconds(30)));
        }

        static void TouchHeartbeat()
        {
            try { File.WriteAllText(HeartbeatFile, DateTime.UtcNow.ToString("o")); } catch (IOException) { }
        }

        static void RecoverOrphans(ConnectionMultiplexer conn, IDatabase redis, string me)
        {
            try
            {
                foreach (var endpoint in conn.GetEndPoints())
                {
                    var server = conn.GetServer(endpoint);
                    if (server.IsReplica) continue;
                    foreach (var key in server.Keys(pattern: ProcessingPrefix + "*"))
                    {
                        var owner = key.ToString().Substring(ProcessingPrefix.Length);
                        if (owner != me && redis.KeyExists(AlivePrefix + owner)) continue; // still alive
                        long moved = 0;
                        while (!redis.ListMove(key, Queue, ListSide.Right, ListSide.Left).IsNull) moved++;
                        if (moved > 0) Console.WriteLine($"Recovered {moved} unfinished vote(s) from {owner}");
                    }
                }
            }
            catch (RedisException ex)
            {
                Console.Error.WriteLine($"Could not check for unfinished votes: {ex.Message}");
            }
        }

        static void TryRedis(Action action)
        {
            try { action(); }
            catch (RedisException ex) { Console.Error.WriteLine($"Redis unavailable: {ex.Message}"); }
        }

        static void Sleep(int milliseconds) => Stop.Token.WaitHandle.WaitOne(milliseconds);

        private static string Env(string name, string fallback)
        {
            var value = Environment.GetEnvironmentVariable(name);
            return string.IsNullOrEmpty(value) ? fallback : value;
        }

        private static NpgsqlConnection OpenDbConnection(string connectionString)
        {
            while (!Stop.IsCancellationRequested)
            {
                try
                {
                    var connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    Console.Error.WriteLine("Connected to db");

                    using var command = connection.CreateCommand();
                    command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                                id VARCHAR(255) NOT NULL UNIQUE,
                                                vote VARCHAR(255) NOT NULL
                                            )";
                    command.ExecuteNonQuery();
                    return connection;
                }
                catch (Exception ex) when (ex is DbException || ex is IOException ||
                                           ex is System.Net.Sockets.SocketException || ex is TimeoutException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    TouchHeartbeat();
                    Sleep(1000);
                }
            }
            return null;
        }

        // One row per voter: a new vote replaces that voter's old one.
        private static void SaveVote(NpgsqlConnection connection, string voterId, string vote)
        {
            using var command = connection.CreateCommand();
            command.CommandText =
                "INSERT INTO votes (id, vote) VALUES (@id, @vote) ON CONFLICT (id) DO UPDATE SET vote = EXCLUDED.vote";
            command.Parameters.AddWithValue("@id", voterId);
            command.Parameters.AddWithValue("@vote", vote);
            command.ExecuteNonQuery();
        }
    }
}
