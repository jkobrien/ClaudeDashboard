# Metrics client

The collection half of the dashboard. Runs on **every** machine; the server (`server.js`, one
directory up) runs only on the hub.

```
client/
  install-client.sh              installs bin/ → ~/.claude-dashboard/bin
  bin/
    pipeline-usage.sh            per-stage token capture for executing-pipeline
    record-pipeline-execution.sh file-locked append to the local metrics store
    export-usage.sh              ccusage → machine-tagged, per-repo usage summary
    sync-metrics.sh              push this machine's files to the hub
```

**This directory is the single source of truth for these scripts.** ClaudeSetup used to vendor its
own copy, which produced three divergent copies of the same two files. It now clones this repo and
runs `install-client.sh` instead.

---

## Install

```sh
./client/install-client.sh
```

Idempotent. Creates `~/.claude-dashboard/{bin,data}`, copies the scripts, and initialises an empty
metrics store if one doesn't exist. Never clobbers an existing store.

ClaudeSetup's `install.sh` does this automatically on every machine.

---

## Collect and push

```sh
~/.claude-dashboard/bin/export-usage.sh        # summarise this machine
~/.claude-dashboard/bin/sync-metrics.sh        # push to the hub (default: mordor)
```

`sync-metrics.sh` runs the export itself, so the second command alone is enough.

---

## Architecture

### Per-machine files, merged at read time

Each machine owns its own files on the hub:

```
<hub>:~/.claude-dashboard/data/
  usage-jarvis.json      pipeline-jarvis.json
  usage-mordor.json      pipeline-mordor.json
  usage-midgard.json     pipeline-midgard.json
```

`server.js` merges them when rendering. **Machines never append to a shared file** — three writers
contending on one JSON over a network is a corruption risk, and the `flock` in
`record-pipeline-execution.sh` only protects local writers.

This is idempotent (a re-push overwrites) and degrades well: if the hub is offline, the machine
keeps recording locally and the next sync catches up. No queue, no partial writes.

### Why the hub is the Linux box

The hub must **receive**, which on a Tailscale fleet means running the Tailscale SSH server —
Linux only. macOS (sandboxed GUI build) and Windows cannot. Every other machine only needs to be an
SSH *client*, which all of them can be.

So `mordor` is the metrics hub, while the Mac remains the secrets hub. Each machine does what it is
actually capable of.

### Summaries travel, transcripts do not

`export-usage.sh` runs `ccusage` against the **local** transcripts and emits a ~30 KB summary. The
transcripts themselves run to hundreds of megabytes per machine (762 MB on the reference Mac) and
are full conversation history, not just numbers. Only the summary leaves the machine.

### Slug normalisation — why per-repo cost works across machines

`ccusage` reports `sessionId` as the project slug, which encodes the **absolute path**. The same
repo is:

| Machine | Slug |
|---|---|
| macOS | `-Users-jkobrien-code-PDP` |
| Linux | `-home-jkobrien-code-PDP` |
| Windows | `-C--Users-jkobrien-code-PDP` |

Merging raw slugs would show one repo as three. `export-usage.sh` resolves each slug against the
machine's **actual repo list** (directories under `$CODE_ROOT` containing `.git`) and emits a repo
*name*. Anything that doesn't resolve to a real repo is reported under `unattributed` rather than
being guessed at — naive string-splitting produces junk entries like `354` or `subagents`.

---

## Relationship to PDP

PDP's `scripts/dashboard/` contains an older, larger variant of the two pipeline scripts (6185 vs
5319 bytes). **It is deliberately left alone** — that repo is shared with other users who depend on
it.

The copies here were taken from what actually runs, not from PDP. The two lineages are no longer
related and nothing re-copies from PDP.

---

## Requirements

| | |
|---|---|
| `ccusage` | for `export-usage.sh` — `npm install` in this repo provides it |
| `python3` | JSON processing in `export-usage.sh` |
| `rsync`, `tailscale` | for `sync-metrics.sh` |
| `jq`, `flock`/`shlock` | for `record-pipeline-execution.sh` |

`pipeline-usage.sh` and `record-pipeline-execution.sh` are POSIX shell — on Windows they need WSL
or Git Bash.
