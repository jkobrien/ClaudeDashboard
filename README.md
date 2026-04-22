# Claude Cost Dashboard

A self-contained, local cost observability dashboard for [Claude Code](https://claude.ai/code). Reads your existing usage data directly from `~/.claude/projects/` — no API keys, no external services, no build step.

## Features

- **7 stat cards** — All Time, This Month, Projection, Last 7 Days, Today, Cache Hit Rate, Model Split
- **AI Insights** — rule-based alerts for spend spikes, Opus overuse, low Haiku adoption, and declining cache hit rates
- **Daily stacked bar chart** — last 30 days broken down by model (Opus 4.7, Opus 4.6, Sonnet, Haiku)
- **This month donut chart** — cost share by model for the current calendar month
- **Routing Opportunities** — sessions running >80% Opus with estimated savings if switched to Sonnet
- **Top Sessions** — highest-cost sessions with per-session model breakdown and routing flags
- **Model Routing Guide** — embedded reference table mapping pipeline stages to recommended models
- **Auto-refresh** — page reloads every 300 seconds with a live countdown

## Prerequisites

- Node.js 18+
- [ccusage](https://www.npmjs.com/package/ccusage) — installed automatically via `npm install`
- Claude Code usage data in `~/.claude/projects/` or `~/.config/claude/projects/`

## Install

```bash
git clone https://github.com/jkobrien/ClaudeDashboard.git
cd ClaudeDashboard
npm install
```

## Run

```bash
node server.js
```

Open [http://localhost:4242](http://localhost:4242).

The first page load takes ~20 seconds while the cache warms from your JSONL files. Subsequent loads are instant until the 5-minute cache TTL expires.

## Options

```bash
# Run on a different port
PORT=8080 node server.js

# Force an immediate data refresh (bypasses 5-minute cache)
curl http://localhost:4242/refresh

# Raw JSON — all computed stats, for scripting or external access
curl http://localhost:4242/api/data
```

## How it works

`server.js` is a single-file pure Node.js HTTP server. On each request it checks an in-memory cache (TTL: 5 minutes). If stale, it calls `ccusage daily`, `ccusage monthly`, and `ccusage session` as subprocesses, parses the JSON output, and derives all dashboard statistics. The HTML page is rendered server-side with data embedded inline — no client-side API calls.

There is no cron, no data files written to disk, and no external services. Everything runs from one `node server.js` command.
