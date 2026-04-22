# Claude Cost Dashboard — Design Spec

**Date:** 2026-04-22  
**Status:** Approved  
**Reference:** NB-PDP-Testing/PDP#1120

---

## Overview

A self-contained, local Node.js dashboard for visualising Claude API costs on macOS. Replicates all panels from the harness dashboard (issue #1120) plus the Mac data panels, combined into one server. No cron, no build step, no external services.

---

## Repository Structure

```
claude-dashboard/
├── server.js           — HTTP server, data fetching, insights engine, HTML rendering
├── package.json        — ccusage npm dependency, start script
├── .gitignore          — node_modules/
└── README.md           — install and run instructions
```

No framework. No build step. `node server.js` is the only runtime command.

---

## Data Layer

### Source

`ccusage` installed as an npm dependency (`./node_modules/.bin/ccusage`). Reads from `~/.claude/projects/` or `~/.config/claude/projects/` JSONL files — same sources as the CLI tool.

### Cache

Three in-memory cache slots: `daily`, `monthly`, `sessions`. Each has a TTL of 5 minutes. On the first request after startup (or after TTL expiry), the server calls all three ccusage commands in parallel via `child_process.execSync` and updates the cache. Subsequent requests within the TTL window are served from cache with no subprocess overhead.

### Commands

| Dataset | Command |
|---|---|
| daily | `ccusage daily --json` |
| monthly | `ccusage monthly --json` |
| sessions | `ccusage session --json` |

### Derived Statistics

Computed from the three datasets on each cache refresh:

| Stat | Derivation |
|---|---|
| All-time total | `monthly.totals.totalCost` |
| This month | `monthly` entry for current YYYY-MM |
| Last 7 days | Sum of last 7 `daily` entries |
| Today | `daily` entry for today's date |
| Month projection | today_cost ÷ day_of_month × days_in_month |
| Cache hit rate | cacheReadTokens ÷ totalTokens (30-day window) |
| Model split (30d) | Per-model cost share from daily modelBreakdowns, last 30 days |
| Routing opportunities | Sessions where Opus share >80%, sorted by estimated Sonnet savings |
| Top sessions | Top 10 sessions by totalCost, with routing flag if Opus >80% |

---

## Dashboard Panels

Served as a single HTML page with data inlined in a `<script>` tag. Charts rendered via Chart.js (CDN, no local asset).

### Stat Cards (row of 7)

1. **All Time** — total spend across all months
2. **This Month** — current calendar month spend
3. **Month Projection** — extrapolated from today's burn rate
4. **Last 7 Days** — rolling 7-day total
5. **Today** — spend since midnight local time
6. **Cache Hit Rate** — % of tokens served from cache (30d)
7. **Model Split (30d)** — inline bar: Opus % / Sonnet % / Haiku %

### AI Insights Panel

Rule-based, fires on every page load. Eight rules from issue #1120:

| Rule | Trigger | Severity |
|---|---|---|
| Month projection | >$1,500 | Critical |
| Month projection | >$800 | High |
| Opus share | >70% with >$100 savings available | Critical |
| Opus share | >60% | High |
| Haiku share | <3% of total | Medium |
| Today spike | Today > $150 | High |
| Cache hit declining | Last 7d rate < prev 7d rate by >10pp | Medium |
| opus-4-7 cost | >$50 spend | Medium |

Each alert shows: severity badge, description, recommended action.

### Charts

- **Daily cost stacked bar chart** — last 30 days, stacked by model (Opus 4.6, Opus 4.7, Sonnet 4.6, Haiku 4.5). Chart.js Bar.
- **This month donut** — cost by model for current month. Chart.js Doughnut.

### Tables

- **Routing Opportunities** — sessions with Opus share >80%. Columns: session ID (truncated), project path, total cost, Opus %, estimated Sonnet saving.
- **Model Routing Guide** — static embedded reference table (all pipeline stages from issue #1120 with recommended model per stage).
- **Top Sessions** — top 10 sessions by cost. Columns: session ID (truncated), project path, cost, models used, routing flag (⚠ if Opus >80%).

### Auto-refresh

Page reloads every 300 seconds. Countdown timer displayed in the header.

---

## HTTP Endpoints

| Endpoint | Response |
|---|---|
| `GET /` | Full dashboard HTML (data inlined) |
| `GET /api/data` | Raw JSON — all derived stats, for optional external access |
| `GET /refresh` | Forces cache invalidation, returns `{"ok": true}` |

Default port: **4242** (matching harness convention). Overridable via `PORT` environment variable.

---

## Security

- No API keys in `server.js` or any committed file.
- `node_modules/` in `.gitignore`.
- `ccusage` reads only local JSONL files — no outbound network calls from the dashboard server itself.
- Chart.js loaded from `cdn.jsdelivr.net` — only external network dependency.

---

## How to Run

```bash
cd claude-dashboard
npm install
node server.js
# Open http://localhost:4242
```

Optional port override:
```bash
PORT=8080 node server.js
```

---

## Out of Scope

- Authentication / access control (local-only tool)
- Harness data fetching (no harness in this setup)
- Persistent data files or cron jobs
- AI-powered insights (rule-based only, no Claude API calls)
- Dark/light theme toggle
