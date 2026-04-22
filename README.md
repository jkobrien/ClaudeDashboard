# Claude Cost Dashboard

Local cost observability dashboard for Claude API usage. Reads data from your `~/.claude/projects/` JSONL files via [ccusage](https://www.npmjs.com/package/ccusage).

## Install

```bash
npm install
```

## Run

```bash
node server.js
```

Then open [http://localhost:4242](http://localhost:4242).

## Optional

Override the port:

```bash
PORT=8080 node server.js
```

Force a data refresh (bypasses 5-minute cache):

```bash
curl http://localhost:4242/refresh
```

Raw JSON endpoint (for external access):

```bash
curl http://localhost:4242/api/data
```

## How it works

The server calls `ccusage` on demand and caches results for 5 minutes. No cron jobs, no data files. The page auto-reloads every 300 seconds.
