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

## Deploying the hub

The dashboard is a **role one machine plays**, not part of setting up a machine. Every machine runs
the client (see [`client/README.md`](client/README.md)); exactly one hosts the server.

**The hub must be Linux.** It has to receive files from the other machines, which on a Tailscale
fleet means running the Tailscale SSH server — and that is Linux-only. macOS (sandboxed GUI build)
and Windows can push but cannot host. Every other machine only needs to be an SSH *client*, which
all of them can be.

Current hub: **mordor**.

### One-off setup on the hub

```sh
# 1. the repo (ClaudeSetup's installer already clones this)
cd ~/code/ClaudeDashboard
npm install

# 2. run it — first page load takes ~20s while the cache warms
node server.js                    # http://localhost:4242

# or in the background
nohup node server.js > ~/.claude-dashboard/server.log 2>&1 &
```

### Expose it across the tailnet

`server.js` binds to `127.0.0.1` deliberately. Rather than changing that, put Tailscale in front —
the dashboard stays unreachable from the public internet while every machine on your tailnet can
open it:

```sh
tailscale serve --bg 4242         # → https://<hub>.<tailnet>.ts.net/
tailscale serve status
tailscale serve --https=443 off   # undo
```

### Keep it running across reboots

```sh
# systemd user service — survives logout, starts at boot with lingering enabled
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/claude-dashboard.service <<'EOF'
[Unit]
Description=Claude cost dashboard
After=network-online.target

[Service]
ExecStart=/usr/bin/node %h/code/ClaudeDashboard/server.js
Restart=on-failure
Environment=PORT=4242

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now claude-dashboard
sudo loginctl enable-linger "$USER"    # start without an active login session
```

### Receiving from other machines

Nothing to configure — the hub just needs Tailscale SSH enabled:

```sh
sudo tailscale up --ssh
```

Each machine then pushes its own files with `client/bin/sync-metrics.sh`, landing as
`~/.claude-dashboard/data/{usage,pipeline}-<machine>.json`. The server merges them at read time,
so a new machine appears in **Cost by Repo** as soon as it first syncs — no hub-side change.

### If the hub moves

Nothing is pinned to a hostname on the server side. Stand the server up on the new box, point the
other machines at it (`sync-metrics.sh <newhub>`, or set `CLAUDE_METRICS_HUB`), and copy across
`~/.claude-dashboard/data/*.json` to retain history.

---

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
