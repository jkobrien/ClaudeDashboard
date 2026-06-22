# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm install        # install dependencies (ccusage only)
node server.js     # start the dashboard (also: npm start)
PORT=8080 node server.js  # run on a different port
curl localhost:4242/refresh   # force cache invalidation without restart
curl localhost:4242/api/data  # raw computed stats as JSON
```

The server binds to `127.0.0.1` only (localhost, no external access). There are no tests, lint, or build steps. First page load takes ~20s while the cache warms from the JSONL files; subsequent loads are instant until the TTL expires.

## Architecture

Single-file Node.js server (`server.js`) with no framework. All logic lives in one file:

1. **Cache layer** — three in-memory slots (`daily`, `monthly`, `sessions`), each with a 5-minute TTL. `refreshIfStale()` calls `ccusage` subprocesses on demand; `invalidateCache()` is triggered by `GET /refresh`.

2. **Data computation** (`compute()`) — calls `refreshIfStale()`, then derives all dashboard statistics from the three raw ccusage datasets: totals, projections, cache hit rates, per-model breakdowns, routing opportunities, and top sessions.

3. **Insights engine** (`generateInsights()`) — rule-based, receives the computed stats object, returns an array of `{severity, title, body, action}` objects. Eight rules matching the triggers defined in the design spec (`docs/superpowers/specs/2026-04-22-claude-dashboard-design.md`).

4. **HTML renderer** (`renderHTML()`) — returns a complete HTML string with inline CSS, Chart.js (CDN), and inline JS for charts and the 300-second auto-reload countdown. Data is embedded as JSON literals in `<script>` tags — no separate API call from the page.

5. **HTTP handler** — three routes: `GET /` (dashboard), `GET /api/data` (raw JSON for external consumers), `GET /refresh` (cache bust).

## Data source

`ccusage` reads Claude usage JSONL files from `~/.claude/projects/` or `~/.config/claude/projects/`. The binary is invoked as `./node_modules/.bin/ccusage <subcommand> --json`. If ccusage fails (e.g. no data yet), the relevant cache slot stays `null` and the dashboard renders with zero values rather than crashing.

## Model grouping

`modelGroup(name)` (server.js:15) maps raw ccusage model names to display groups: `Opus 4.8`, `Opus 4.7`, `Opus 4.6`, `Sonnet`, `Haiku`, `Other`. All charts, tables, and insights use these groups.

**Gotcha:** each Opus branch special-cases a specific version (`4-8`/`4.8`, `4-7`/`4.7`); *every other* Opus version falls through to `Opus 4.6`. So a newer Opus release (e.g. a future 4.9) is silently mislabeled as `Opus 4.6` until you add an explicit branch. When a new model family ships, add the branch in `modelGroup()` first, then thread the new group name through every place it's hardcoded — there is no single source of truth for the group list:
- `MODEL_COLORS` (server.js:24) — chart/legend color
- `.tag-*` CSS class (server.js:~393) and the `cls` ternary in the sessions table (server.js:~486)
- `opusCost30` sum (server.js:~133) — so it counts toward the Opus-share insight
- `chartGroups` array (server.js:~147) — so it appears in the daily bar + month donut
- `opusLatestCost` / the flagship-spend insight (server.js:~139, ~269) — retarget to the newest model
