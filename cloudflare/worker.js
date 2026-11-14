// Cloudflare Worker: a reliable clock for the GitHub watcher.
//
// GitHub's own cron is best-effort and often skips runs on small repos, so every 10 minutes this
// Worker asks GitHub to start the "Watch App Review appointments" workflow (workflow_dispatch runs
// start within seconds). It also acts as a watchdog: if the watcher's saved results go stale, or
// GitHub refuses to start the workflow, it pushes an alert to your phone through ntfy.
//
// Secrets:   GITHUB_TOKEN  fine-grained token for this repo only, "Actions: Read and write"
//            NTFY_TOPIC    same topic the watcher uses
// Variables: REPO (owner/name), WORKFLOW (file name), STALE_MINUTES

const GH = "https://api.github.com";
const MIN = 60_000;

async function gh(env, path, init = {}) {
  return fetch(`${GH}${path}`, {
    ...init,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      "User-Agent": "app-review-watcher-clock",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(init.headers || {}),
    },
  });
}

async function push(env, title, message, url) {
  if (!env.NTFY_TOPIC) return;
  const body = { topic: env.NTFY_TOPIC, title, message, priority: 4, tags: ["warning"] };
  if (url) body.click = url;
  await fetch("https://ntfy.sh/", { method: "POST", body: JSON.stringify(body) }).catch(() => {});
}

async function dispatch(env) {
  const res = await gh(env, `/repos/${env.REPO}/actions/workflows/${env.WORKFLOW}/dispatches`, {
    method: "POST",
    body: JSON.stringify({ ref: "main" }),
  });
  if (res.status === 204) return { ok: true };
  return { ok: false, status: res.status, detail: (await res.text()).slice(0, 200) };
}

async function lastCheck(env) {
  const res = await gh(env, `/repos/${env.REPO}/contents/state.json?ref=state`, {
    headers: { Accept: "application/vnd.github.raw+json" },
  });
  if (!res.ok) return null;
  const state = await res.json();
  return state.lastCheck ? Date.parse(state.lastCheck) : null;
}

// Stateless "alert once per window": true for the first tick after `age` crosses `start`,
// then again every `every` minutes, so a lasting problem nags a few times a day, not every 10 minutes.
const due = (ageMin, start, every) => ageMin >= start && (ageMin - start) % every < 10;

async function tick(env, scheduledTime) {
  const actionsUrl = `https://github.com/${env.REPO}/actions`;
  const result = await dispatch(env);
  if (!result.ok) {
    console.log("dispatch failed", result.status, result.detail);
    // At most once an hour (the tick in the first 10 minutes of the hour).
    if (new Date(scheduledTime).getUTCMinutes() < 10) {
      const why = result.status === 401 ? "its GitHub token was rejected (expired or revoked?)" : `GitHub answered HTTP ${result.status}`;
      await push(env, "App Review watcher can't start", `The Cloudflare clock couldn't start the watcher: ${why}.`, actionsUrl);
    }
  }

  const checked = await lastCheck(env).catch(() => null);
  if (checked) {
    const ageMin = Math.floor((Date.now() - checked) / MIN);
    const stale = Number(env.STALE_MINUTES || 45);
    console.log(`last successful check ${ageMin} min ago`);
    if (due(ageMin, stale, 360)) {
      await push(env, "App Review watcher has stopped checking", `No successful check of Apple's schedule for ${ageMin} minutes.`, actionsUrl);
    }
  }
}

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(tick(env, event.scheduledTime));
  },
  // Visiting the Worker URL only reports health; it never starts a run.
  async fetch(_request, env) {
    const checked = await lastCheck(env).catch(() => null);
    const body = {
      watcher: env.REPO,
      lastSuccessfulCheck: checked ? new Date(checked).toISOString() : null,
      minutesAgo: checked ? Math.floor((Date.now() - checked) / MIN) : null,
    };
    return new Response(JSON.stringify(body, null, 2), { headers: { "content-type": "application/json" } });
  },
};
