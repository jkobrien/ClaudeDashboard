# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm install        # install dependencies (ccusage only)
node server.js     # start the dashboard on http://localhost:4242
PORT=8080 node server.js  # run on a different port
curl localhost:4242/refresh  # force cache invalidation without restart
```

## Architecture

Single-file Node.js server (`server.js`) with no framework. All logic lives in one file:

1. **Cache layer** — three in-memory slots (`daily`, `monthly`, `sessions`), each with a 5-minute TTL. `refreshIfStale()` calls `ccusage` subprocesses on demand; `invalidateCache()` is triggered by `GET /refresh`.

2. **Data computation** (`compute()`) — calls `refreshIfStale()`, then derives all dashboard statistics from the three raw ccusage datasets: totals, projections, cache hit rates, per-model breakdowns, routing opportunities, and top sessions.

3. **Insights engine** (`generateInsights()`) — rule-based, receives the computed stats object, returns an array of `{severity, title, body, action}` objects. Eight rules matching the triggers defined in the design spec.

4. **HTML renderer** (`renderHTML()`) — returns a complete HTML string with inline CSS, Chart.js (CDN), and inline JS for charts and the 300-second auto-reload countdown. Data is embedded as JSON literals in `<script>` tags — no separate API call from the page.

5. **HTTP handler** — three routes: `GET /` (dashboard), `GET /api/data` (raw JSON for external consumers), `GET /refresh` (cache bust).

## Data source

`ccusage` reads Claude usage JSONL files from `~/.claude/projects/` or `~/.config/claude/projects/`. The binary is invoked as `./node_modules/.bin/ccusage <subcommand> --json`. If ccusage fails (e.g. no data yet), the relevant cache slot stays `null` and the dashboard renders with zero values rather than crashing.

## Model grouping

`modelGroup(name)` maps raw ccusage model names to four display groups: `Opus 4.7`, `Opus 4.6`, `Sonnet`, `Haiku`. All charts, tables, and insights use these groups. Add new model families here first when Claude releases new models.
