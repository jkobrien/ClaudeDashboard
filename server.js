'use strict';

const http = require('http');
const { execSync } = require('child_process');
const path = require('path');

const PORT = parseInt(process.env.PORT || '4242', 10);
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes
const CCUSAGE = path.join(__dirname, 'node_modules', '.bin', 'ccusage');

// ---------------------------------------------------------------------------
// Model helpers
// ---------------------------------------------------------------------------

function modelGroup(name = '') {
  const n = name.toLowerCase();
  if (n.includes('opus') && (n.includes('4-7') || n.includes('4.7'))) return 'Opus 4.7';
  if (n.includes('opus')) return 'Opus 4.6';
  if (n.includes('sonnet')) return 'Sonnet';
  if (n.includes('haiku')) return 'Haiku';
  return 'Other';
}

const MODEL_COLORS = {
  'Opus 4.7': '#ef4444',
  'Opus 4.6': '#f97316',
  'Sonnet':   '#3b82f6',
  'Haiku':    '#22c55e',
  'Other':    '#6b7280',
};

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

const cache = {
  daily:    { data: null, ts: 0 },
  monthly:  { data: null, ts: 0 },
  sessions: { data: null, ts: 0 },
};

function runCcusage(subcommand) {
  try {
    const raw = execSync(
      `"${CCUSAGE}" ${subcommand} --json 2>/dev/null`,
      { timeout: 60000, maxBuffer: 100 * 1024 * 1024 }
    );
    return JSON.parse(raw.toString('utf8'));
  } catch (e) {
    console.error(`[ccusage ${subcommand}] failed:`, e.message);
    return null;
  }
}

function refreshIfStale() {
  const now = Date.now();
  if (now - cache.daily.ts > CACHE_TTL) {
    console.log(`[${new Date().toISOString()}] refreshing daily…`);
    cache.daily.data = runCcusage('daily');
    cache.daily.ts = now;
  }
  if (now - cache.monthly.ts > CACHE_TTL) {
    console.log(`[${new Date().toISOString()}] refreshing monthly…`);
    cache.monthly.data = runCcusage('monthly');
    cache.monthly.ts = now;
  }
  if (now - cache.sessions.ts > CACHE_TTL) {
    console.log(`[${new Date().toISOString()}] refreshing sessions…`);
    cache.sessions.data = runCcusage('session');
    cache.sessions.ts = now;
  }
}

function invalidateCache() {
  Object.keys(cache).forEach(k => { cache[k].ts = 0; });
}

// ---------------------------------------------------------------------------
// Data computation
// ---------------------------------------------------------------------------

function compute() {
  refreshIfStale();

  const daily    = (cache.daily.data    || {}).daily    || [];
  const monthly  = (cache.monthly.data  || {}).monthly  || [];
  const sessions = (cache.sessions.data || {}).sessions || [];

  const now         = new Date();
  const today       = now.toISOString().split('T')[0];
  const thisMonth   = today.slice(0, 7);
  const dayOfMonth  = now.getDate();
  const daysInMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();

  // --- Core stats ---
  const allTime      = monthly.reduce((s, m) => s + (m.totalCost || 0), 0);
  const monthEntry   = monthly.find(m => m.month === thisMonth) || {};
  const thisMonthCost = monthEntry.totalCost || 0;
  const todayEntry   = daily.find(d => d.date === today) || {};
  const todayCost    = todayEntry.totalCost || 0;

  const last7Entries = daily.slice(-7);
  const last7Cost    = last7Entries.reduce((s, d) => s + (d.totalCost || 0), 0);

  const projection = dayOfMonth > 0 ? (thisMonthCost / dayOfMonth) * daysInMonth : 0;

  // --- Cache hit rate (30d) ---
  const last30 = daily.slice(-30);

  function cacheRate(entries) {
    const reads = entries.reduce((s, d) => s + (d.cacheReadTokens || 0), 0);
    const inp   = entries.reduce((s, d) => s + (d.inputTokens || 0), 0);
    return inp + reads > 0 ? (reads / (inp + reads)) * 100 : 0;
  }

  const cacheHitRate  = cacheRate(last30);
  const prev7Entries  = daily.slice(-14, -7);
  const last7Cache    = cacheRate(last7Entries);
  const prev7Cache    = cacheRate(prev7Entries);
  const cacheDeclining = prev7Entries.length >= 3 && (prev7Cache - last7Cache) > 10;

  // --- Model split (30d) ---
  const modelCosts30 = {};
  last30.forEach(d => {
    (d.modelBreakdowns || []).forEach(b => {
      const g = modelGroup(b.modelName);
      modelCosts30[g] = (modelCosts30[g] || 0) + (b.cost || 0);
    });
  });
  const total30    = Object.values(modelCosts30).reduce((s, v) => s + v, 0);
  const opusCost30 = (modelCosts30['Opus 4.6'] || 0) + (modelCosts30['Opus 4.7'] || 0);
  const opusShare30 = total30 > 0 ? (opusCost30 / total30) * 100 : 0;
  const haikuShare30 = total30 > 0 ? ((modelCosts30['Haiku'] || 0) / total30) * 100 : 0;

  // Estimated Sonnet saving if all Opus were switched (Sonnet ~20% of Opus cost)
  const potentialSaving30 = opusCost30 * 0.8;

  // opus-4-7 spend this month
  const opus47Cost = (monthEntry.modelBreakdowns || [])
    .filter(b => modelGroup(b.modelName) === 'Opus 4.7')
    .reduce((s, b) => s + (b.cost || 0), 0);

  // --- Daily chart data (last 30 days) ---
  const chartLabels = last30.map(d => d.date.slice(5)); // MM-DD
  const chartGroups = ['Opus 4.7', 'Opus 4.6', 'Sonnet', 'Haiku'];
  const chartDatasets = chartGroups.map(g => ({
    label: g,
    backgroundColor: MODEL_COLORS[g],
    data: last30.map(d => {
      return (d.modelBreakdowns || [])
        .filter(b => modelGroup(b.modelName) === g)
        .reduce((s, b) => s + (b.cost || 0), 0);
    }),
  }));

  // --- This month donut ---
  const donutData = chartGroups.map(g =>
    (monthEntry.modelBreakdowns || [])
      .filter(b => modelGroup(b.modelName) === g)
      .reduce((s, b) => s + (b.cost || 0), 0)
  );

  // --- Routing opportunities ---
  const routingOpps = sessions
    .map(s => {
      const opusCost = (s.modelBreakdowns || [])
        .filter(b => modelGroup(b.modelName).startsWith('Opus'))
        .reduce((a, b) => a + (b.cost || 0), 0);
      const opusPct = s.totalCost > 0 ? (opusCost / s.totalCost) * 100 : 0;
      const saving  = opusCost * 0.8;
      return { ...s, opusCost, opusPct, saving };
    })
    .filter(s => s.opusPct > 80 && s.totalCost > 0.01)
    .sort((a, b) => b.saving - a.saving)
    .slice(0, 15);

  // --- Top sessions ---
  const topSessions = [...sessions]
    .sort((a, b) => (b.totalCost || 0) - (a.totalCost || 0))
    .slice(0, 10)
    .map(s => {
      const opusCost = (s.modelBreakdowns || [])
        .filter(b => modelGroup(b.modelName).startsWith('Opus'))
        .reduce((a, b) => a + (b.cost || 0), 0);
      const opusPct = s.totalCost > 0 ? (opusCost / s.totalCost) * 100 : 0;
      return { ...s, opusPct };
    });

  return {
    allTime, thisMonthCost, todayCost, last7Cost, projection,
    cacheHitRate, cacheDeclining, last7Cache, prev7Cache,
    modelCosts30, total30, opusShare30, haikuShare30, potentialSaving30, opus47Cost,
    chartLabels, chartDatasets,
    donutData, chartGroups,
    routingOpps, topSessions,
    sessionCount: sessions.length,
    refreshedAt: new Date(Math.max(cache.daily.ts, cache.monthly.ts, cache.sessions.ts)).toISOString(),
  };
}

// ---------------------------------------------------------------------------
// AI Insights (rule-based)
// ---------------------------------------------------------------------------

function generateInsights(d) {
  const insights = [];

  if (d.projection > 1500) {
    insights.push({
      severity: 'critical',
      title: 'Month projection exceeds $1,500',
      body: `On track for $${d.projection.toFixed(0)} this month. Immediate action required.`,
      action: 'Switch all standard subagents to Sonnet. Reserve Opus for architect and challenger stages only.',
    });
  } else if (d.projection > 800) {
    insights.push({
      severity: 'high',
      title: 'Month projection exceeds $800',
      body: `On track for $${d.projection.toFixed(0)} this month.`,
      action: 'Review Opus usage — ensure all Agent calls include an explicit model: parameter.',
    });
  }

  if (d.opusShare30 > 70 && d.potentialSaving30 > 100) {
    insights.push({
      severity: 'critical',
      title: `Opus share is ${d.opusShare30.toFixed(0)}% of 30-day spend`,
      body: `Estimated $${d.potentialSaving30.toFixed(0)} in savings available by routing to Sonnet.`,
      action: 'Add explicit model: "claude-sonnet-4-6" to every Agent call that doesn\'t require Opus.',
    });
  } else if (d.opusShare30 > 60) {
    insights.push({
      severity: 'high',
      title: `Opus share is ${d.opusShare30.toFixed(0)}% of 30-day spend`,
      body: 'Target is <50% Opus.',
      action: 'Check session inheritance — subagents may be inheriting parent Opus model.',
    });
  }

  if (d.haikuShare30 < 3 && d.total30 > 10) {
    insights.push({
      severity: 'medium',
      title: 'Haiku usage is below 3%',
      body: `Haiku share: ${d.haikuShare30.toFixed(1)}%. Lightweight tasks could use Haiku.`,
      action: 'Route Explore, comment-analyzer, docs, and code-simplifier subagents to Haiku.',
    });
  }

  if (d.todayCost > 150) {
    insights.push({
      severity: 'high',
      title: `Today's spend is $${d.todayCost.toFixed(2)}`,
      body: 'High single-day cost detected.',
      action: 'Check active sessions — a multi-agent pipeline may be running with inherited Opus.',
    });
  }

  if (d.cacheDeclining) {
    insights.push({
      severity: 'medium',
      title: 'Cache hit rate declining',
      body: `Last 7d: ${d.last7Cache.toFixed(0)}%, prev 7d: ${d.prev7Cache.toFixed(0)}% (−${(d.prev7Cache - d.last7Cache).toFixed(0)}pp).`,
      action: 'Check if long system prompts are being broken across requests. Enable prompt caching where possible.',
    });
  }

  if (d.opus47Cost > 50) {
    insights.push({
      severity: 'medium',
      title: `Opus 4.7 spend is $${d.opus47Cost.toFixed(2)} this month`,
      body: 'Opus 4.7 is the most expensive model. Confirm it is being used intentionally.',
      action: 'Audit sessions using claude-opus-4-7 — consider downgrading to Opus 4.6 or Sonnet.',
    });
  }

  return insights;
}

// ---------------------------------------------------------------------------
// Formatting helpers (used inside the HTML template)
// ---------------------------------------------------------------------------

const $ = n => `$${Number(n || 0).toFixed(2)}`;
const pct = n => `${Number(n || 0).toFixed(1)}%`;
const shortId = id => (id || '').slice(0, 8);
const shortPath = p => {
  if (!p) return '—';
  const parts = (p || '').split('/');
  return parts.length > 2 ? '…/' + parts.slice(-2).join('/') : p;
};

function severityBadge(s) {
  const map = { critical: '#ef4444', high: '#f97316', medium: '#eab308' };
  const color = map[s] || '#6b7280';
  return `<span style="background:${color};color:#fff;border-radius:4px;padding:2px 8px;font-size:11px;font-weight:700;text-transform:uppercase;">${s}</span>`;
}

// ---------------------------------------------------------------------------
// HTML render
// ---------------------------------------------------------------------------

function renderHTML(d) {
  const insights = generateInsights(d);
  const insightBorderColor = s => ({ critical: '#ef4444', high: '#f97316', medium: '#eab308' }[s] || '#6b7280');

  const statCards = [
    { label: 'All Time',        value: $(d.allTime),       sub: '' },
    { label: 'This Month',      value: $(d.thisMonthCost), sub: '' },
    { label: 'Month Projection',value: $(d.projection),    sub: 'at current burn rate' },
    { label: 'Last 7 Days',     value: $(d.last7Cost),     sub: '' },
    { label: 'Today',           value: $(d.todayCost),     sub: '' },
    { label: 'Cache Hit Rate',  value: pct(d.cacheHitRate),sub: '30-day window' },
    {
      label: 'Model Split (30d)',
      value: `${pct(d.opusShare30)} Opus`,
      sub: `${pct(d.total30 > 0 ? ((d.modelCosts30['Sonnet'] || 0) / d.total30) * 100 : 0)} Sonnet · ${pct(d.haikuShare30)} Haiku`,
    },
  ];

  const routingGuide = [
    ['Architect (Stage 1)',          'Opus'],
    ['Builder — high blast radius',  'Opus'],
    ['Builder — standard',           'Sonnet'],
    ['Code Reviewer (Stage 3)',       'Sonnet'],
    ['Security Reviewer (Stage 3b)', 'Sonnet'],
    ['Type Design Auditor (Stage 3c)','Sonnet'],
    ['Architecture Reviewer (Stage 4)','Opus'],
    ['Challenger (Stage 5)',          'Opus'],
    ['QA / AC Verification (Stage 6)','Sonnet'],
    ['Explore subagent',             'Haiku'],
    ['code-simplifier',              'Haiku'],
    ['comment-analyzer',             'Haiku'],
    ['Docs / config / README',       'Haiku'],
  ];

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Claude Cost Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js"></script>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg:      #0f172a;
    --card:    #1e293b;
    --border:  #334155;
    --text:    #e2e8f0;
    --muted:   #94a3b8;
    --accent:  #3b82f6;
  }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 14px; line-height: 1.5; min-height: 100vh; }
  header { background: var(--card); border-bottom: 1px solid var(--border); padding: 16px 24px; display: flex; align-items: center; justify-content: space-between; }
  header h1 { font-size: 18px; font-weight: 700; color: var(--text); }
  header .meta { color: var(--muted); font-size: 12px; text-align: right; }
  main { max-width: 1400px; margin: 0 auto; padding: 24px; display: flex; flex-direction: column; gap: 24px; }
  .section-title { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); margin-bottom: 12px; }
  /* Stat cards */
  .stat-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 12px; }
  @media (max-width: 1200px) { .stat-grid { grid-template-columns: repeat(4, 1fr); } }
  @media (max-width: 600px)  { .stat-grid { grid-template-columns: repeat(2, 1fr); } }
  .stat-card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
  .stat-card .label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); margin-bottom: 8px; }
  .stat-card .value { font-size: 22px; font-weight: 700; color: var(--text); }
  .stat-card .sub   { font-size: 11px; color: var(--muted); margin-top: 4px; }
  /* Insights */
  .insights { display: flex; flex-direction: column; gap: 10px; }
  .insight  { background: var(--card); border: 1px solid var(--border); border-left-width: 4px; border-radius: 8px; padding: 14px 16px; display: flex; flex-direction: column; gap: 6px; }
  .insight .row { display: flex; align-items: center; gap: 10px; }
  .insight .title { font-weight: 600; font-size: 14px; }
  .insight .body  { color: var(--muted); font-size: 13px; }
  .insight .action { font-size: 12px; color: #93c5fd; margin-top: 2px; }
  .insight .action::before { content: '→ '; }
  .no-insights { color: var(--muted); font-size: 13px; padding: 12px 0; }
  /* Charts */
  .chart-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 16px; }
  @media (max-width: 900px) { .chart-grid { grid-template-columns: 1fr; } }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px; }
  .card-title { font-size: 13px; font-weight: 600; color: var(--muted); margin-bottom: 16px; text-transform: uppercase; letter-spacing: 0.05em; }
  .chart-wrap { position: relative; }
  /* Tables */
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); padding: 8px 12px; border-bottom: 1px solid var(--border); }
  td { padding: 8px 12px; border-bottom: 1px solid rgba(51,65,85,0.5); color: var(--text); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(255,255,255,0.03); }
  .flag { color: #f97316; font-size: 13px; }
  .model-pill { display: inline-block; border-radius: 4px; padding: 1px 6px; font-size: 11px; font-weight: 600; color: #fff; margin: 1px; }
  .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  @media (max-width: 900px) { .two-col { grid-template-columns: 1fr; } }
  .countdown { font-size: 12px; color: var(--muted); }
  .tag-opus47  { background: #ef4444; }
  .tag-opus46  { background: #f97316; }
  .tag-sonnet  { background: #3b82f6; }
  .tag-haiku   { background: #22c55e; }
  .tag-other   { background: #6b7280; }
</style>
</head>
<body>
<header>
  <h1>Claude Cost Dashboard</h1>
  <div class="meta">
    <div>Data refreshed: ${d.refreshedAt.replace('T', ' ').slice(0, 19)} UTC</div>
    <div class="countdown" id="countdown">Page reloads in <span id="timer">300</span>s</div>
  </div>
</header>
<main>

  <!-- Stat cards -->
  <section>
    <div class="section-title">Overview</div>
    <div class="stat-grid">
      ${statCards.map(c => `
      <div class="stat-card">
        <div class="label">${c.label}</div>
        <div class="value">${c.value}</div>
        ${c.sub ? `<div class="sub">${c.sub}</div>` : ''}
      </div>`).join('')}
    </div>
  </section>

  <!-- AI Insights -->
  <section>
    <div class="section-title">AI Insights</div>
    <div class="insights">
      ${insights.length === 0
        ? '<div class="no-insights">✓ No issues detected. Spend and model routing look healthy.</div>'
        : insights.map(i => `
      <div class="insight" style="border-left-color:${insightBorderColor(i.severity)};">
        <div class="row">${severityBadge(i.severity)} <span class="title">${i.title}</span></div>
        <div class="body">${i.body}</div>
        <div class="action">${i.action}</div>
      </div>`).join('')}
    </div>
  </section>

  <!-- Charts -->
  <section>
    <div class="section-title">Cost by Model</div>
    <div class="chart-grid">
      <div class="card">
        <div class="card-title">Daily Cost — Last 30 Days</div>
        <div class="chart-wrap"><canvas id="dailyChart" height="200"></canvas></div>
      </div>
      <div class="card">
        <div class="card-title">This Month by Model</div>
        <div class="chart-wrap"><canvas id="donutChart" height="200"></canvas></div>
      </div>
    </div>
  </section>

  <!-- Routing Opportunities + Top Sessions -->
  <section>
    <div class="two-col">
      <div class="card">
        <div class="card-title">Routing Opportunities (Opus &gt; 80%)</div>
        ${d.routingOpps.length === 0
          ? '<p style="color:var(--muted);font-size:13px;">No sessions with >80% Opus found.</p>'
          : `<table>
          <thead><tr><th>Session</th><th>Project</th><th>Cost</th><th>Opus%</th><th>Est. Saving</th></tr></thead>
          <tbody>
            ${d.routingOpps.map(s => `
            <tr>
              <td><code>${shortId(s.sessionId)}</code></td>
              <td title="${s.projectPath || ''}">${shortPath(s.projectPath)}</td>
              <td>${$(s.totalCost)}</td>
              <td>${pct(s.opusPct)}</td>
              <td style="color:#22c55e;">${$(s.saving)}</td>
            </tr>`).join('')}
          </tbody>
        </table>`}
      </div>

      <div class="card">
        <div class="card-title">Top Sessions by Cost</div>
        <table>
          <thead><tr><th>Session</th><th>Cost</th><th>Models</th><th></th></tr></thead>
          <tbody>
            ${d.topSessions.map(s => {
              const models = [...new Set((s.modelsUsed || []).map(modelGroup))];
              const pills = models.map(m => {
                const cls = m === 'Opus 4.7' ? 'tag-opus47' : m === 'Opus 4.6' ? 'tag-opus46' : m === 'Sonnet' ? 'tag-sonnet' : m === 'Haiku' ? 'tag-haiku' : 'tag-other';
                return `<span class="model-pill ${cls}">${m}</span>`;
              }).join('');
              return `
            <tr>
              <td><code>${shortId(s.sessionId)}</code><br><span style="color:var(--muted);font-size:11px;">${shortPath(s.projectPath)}</span></td>
              <td>${$(s.totalCost)}</td>
              <td>${pills}</td>
              <td>${s.opusPct > 80 ? '<span class="flag" title="High Opus share">⚠</span>' : ''}</td>
            </tr>`;
            }).join('')}
          </tbody>
        </table>
      </div>
    </div>
  </section>

  <!-- Model Routing Guide -->
  <section>
    <div class="card">
      <div class="card-title">Model Routing Guide</div>
      <table>
        <thead><tr><th>Task / Stage</th><th>Recommended Model</th></tr></thead>
        <tbody>
          ${routingGuide.map(([task, model]) => {
            const cls = model === 'Opus' ? 'tag-opus46' : model === 'Sonnet' ? 'tag-sonnet' : 'tag-haiku';
            return `<tr><td>${task}</td><td><span class="model-pill ${cls}">${model}</span></td></tr>`;
          }).join('')}
        </tbody>
      </table>
    </div>
  </section>

</main>

<script>
(function() {
  // Charts
  const dailyCtx = document.getElementById('dailyChart').getContext('2d');
  new Chart(dailyCtx, {
    type: 'bar',
    data: {
      labels: ${JSON.stringify(d.chartLabels)},
      datasets: ${JSON.stringify(d.chartDatasets)},
    },
    options: {
      responsive: true,
      plugins: { legend: { labels: { color: '#94a3b8', boxWidth: 12 } } },
      scales: {
        x: { stacked: true, ticks: { color: '#64748b', maxRotation: 45 }, grid: { color: '#1e293b' } },
        y: { stacked: true, ticks: { color: '#64748b', callback: v => '$' + v.toFixed(2) }, grid: { color: '#334155' } },
      },
    },
  });

  const donutCtx = document.getElementById('donutChart').getContext('2d');
  new Chart(donutCtx, {
    type: 'doughnut',
    data: {
      labels: ${JSON.stringify(d.chartGroups)},
      datasets: [{ data: ${JSON.stringify(d.donutData)}, backgroundColor: ${JSON.stringify(d.chartGroups.map(g => MODEL_COLORS[g]))} }],
    },
    options: {
      responsive: true,
      plugins: {
        legend: { position: 'bottom', labels: { color: '#94a3b8', boxWidth: 12 } },
        tooltip: { callbacks: { label: ctx => ' $' + ctx.parsed.toFixed(2) } },
      },
    },
  });

  // Auto-refresh countdown
  let t = 300;
  const el = document.getElementById('timer');
  setInterval(() => { t--; if (el) el.textContent = t; if (t <= 0) location.reload(); }, 1000);
})();
</script>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (url === '/refresh') {
    invalidateCache();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, message: 'Cache invalidated' }));
    return;
  }

  if (url === '/api/data') {
    try {
      const d = compute();
      res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify(d, null, 2));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (url === '/') {
    try {
      const d = compute();
      const html = renderHTML(d);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('Error: ' + e.message + '\n' + e.stack);
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Claude Dashboard running → http://localhost:${PORT}`);
  console.log('Warming cache…');
  try { compute(); } catch (e) { console.error('Initial cache warm failed:', e.message); }
});
