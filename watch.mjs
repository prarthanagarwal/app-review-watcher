#!/usr/bin/env node
// App Review Watcher
// Watches Apple's public "Meet with Apple" schedule for App Review appointments and
// alerts when a new one is posted or when a full one opens up.
//
// It runs in two places that cooperate:
//   • GitHub Actions ("cloud"): checks every 10 minutes, pushes phone alerts via ntfy.
//   • Your Mac: mirrors the cloud's results for the menu bar app and shows banners.
//     If the cloud hasn't checked recently, the Mac checks Apple itself as a fallback.
//
// Flags:  --force        check Apple from this machine right now
//         --test-notify  send a test alert on every channel and exit

import { chromium } from "playwright-core";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const ARGS = new Set(process.argv.slice(2));
const CLOUD = process.env.GITHUB_ACTIONS === "true";
const DATA_DIR = process.env.WATCH_DATA_DIR
  || (CLOUD ? process.cwd() : path.join(os.homedir(), "Library", "Application Support", "AppReviewWatcher"));
const STATE_FILE = path.join(DATA_DIR, "state.json");
const LOCK_FILE = path.join(DATA_DIR, "watch.lock");
const LOG_FILE = path.join(DATA_DIR, "watch.log");

fs.mkdirSync(DATA_DIR, { recursive: true });
const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const config = readJSON(path.join(DATA_DIR, "config.json")) || {};

const NTFY_TOPIC = process.env.NTFY_TOPIC || config.ntfyTopic || "";
const HEALTHCHECK_URL = process.env.HEALTHCHECK_URL || config.healthcheckUrl || "";
const REPO = process.env.GITHUB_REPOSITORY || config.repo || ""; // owner/name, where the cloud publishes its state
const TIMEZONE = process.env.WATCH_TIMEZONE || config.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone;
const MATCH = new RegExp(process.env.WATCH_MATCH || config.match || "app\\s*review", "i");

const BASE = "https://developer.apple.com";
const LISTING = `${BASE}/events/view/upcoming-events/`;
const EVENT_LINKS = 'a[href*="/events/view/"][href*="/dashboard"]';
const MIN = 60_000;
const CLOUD_FRESH_MS = 25 * MIN;   // cloud result newer than this => Mac doesn't need to check
const CLOUD_DOWN_MS = 90 * MIN;    // cloud silent for this long => tell the user once
const ERRORS_BEFORE_ALERT = 3;

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── State ───────────────────────────────────────────────────────────────────

function emptyState() {
  return { version: 2, initialized: false, source: CLOUD ? "cloud" : "mac", lastCheck: null, lastAttempt: null,
    lastError: null, errorCount: 0, seenEvents: {}, events: {}, alerts: [] };
}

function normalize(s) {
  if (!s || typeof s !== "object") return emptyState();
  const out = { ...emptyState(), ...s, version: 2 };
  if (s.version !== 2) { // migrate from the first version of this script
    out.initialized = s.firstRun === false;
    out.source = "mac";
    out.alerts = [];
  }
  out.seenEvents = Object.fromEntries(Object.entries(s.seenEvents || {}).map(([id, v]) => [id, typeof v === "string" ? v : v?.firstSeen || new Date().toISOString()]));
  out.events = Object.fromEntries(Object.entries(s.events || {}).filter(([, e]) => e && e.id && e.status));
  out.alerts = (out.alerts || []).filter((a) => a && a.key && a.time);
  for (const k of ["firstRun", "knownHash", "knownText", "listingCount"]) delete out[k];
  return out;
}

const loadState = () => normalize(readJSON(STATE_FILE));
function saveState(s) {
  const tmp = `${STATE_FILE}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
  fs.renameSync(tmp, STATE_FILE); // atomic, so the menu bar app never reads a half-written file
}

// ── Notifications ───────────────────────────────────────────────────────────

function banner(title, message) {
  if (CLOUD || process.platform !== "darwin") return;
  try {
    const esc = (t) => String(t).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    execFileSync("osascript", ["-e", `display notification "${esc(message)}" with title "${esc(title)}" sound name "Glass"`], { timeout: 10_000 });
  } catch (e) { log("mac banner failed:", e.message.split("\n")[0]); }
}

async function push(title, message, { url, priority = 3, tags = ["calendar"] } = {}) {
  if (!NTFY_TOPIC) return false;
  const body = { topic: NTFY_TOPIC, title, message, priority, tags };
  if (url) { body.click = url; body.actions = [{ action: "view", label: "Open page", url }]; }
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch("https://ntfy.sh/", { method: "POST", body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) });
      if (res.ok) return true;
      log(`phone push rejected (HTTP ${res.status})`);
    } catch (e) { log(`phone push failed (attempt ${attempt}):`, e.message); }
    await sleep(2000 * attempt);
  }
  return false;
}

async function notify(title, message, opts = {}) {
  log("ALERT:", title, "—", message);
  banner(title, message);
  await push(title, message, opts);
}

async function heartbeat(ok) {
  if (!HEALTHCHECK_URL) return;
  try { await fetch(HEALTHCHECK_URL.replace(/\/$/, "") + (ok ? "" : "/fail"), { signal: AbortSignal.timeout(10_000) }); }
  catch (e) { log("heartbeat ping failed:", e.message); }
}

// ── Parsing ─────────────────────────────────────────────────────────────────

const MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
const monthIndex = (name) => MONTHS.indexOf(String(name).toLowerCase());
const pad = (n) => String(n).padStart(2, "0");

// "November 17-18, 2026" | "November 30 - December 1, 2026" | "November 18, 2026"
function parseDates(text) {
  const m = text.match(/([A-Z][a-z]+) (\d{1,2})(?:\s*[-–]\s*(?:([A-Z][a-z]+) )?(\d{1,2}))?, (\d{4})/);
  if (!m || monthIndex(m[1]) < 0) return { dates: null, startDate: null, endDate: null };
  const year = +m[5], m1 = monthIndex(m[1]), m2 = m[3] ? monthIndex(m[3]) : m1;
  const startDate = `${year}-${pad(m1 + 1)}-${pad(+m[2])}`;
  const endDate = m[4] ? `${m2 < m1 ? year + 1 : year}-${pad(m2 + 1)}-${pad(+m[4])}` : startDate;
  return { dates: m[0], startDate, endDate };
}

// "Submit a request by November 16 1:30 p.m. (GMT+5:30)."  →  ISO timestamp
function parseDeadline(text, startDate) {
  const m = text.match(/(?:submit a request|register|sign up|request)\s+by\s+([A-Z][a-z]+) (\d{1,2}),?\s+(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\s*\(([A-Z]{2,5})?\s*([+-]\d{1,2})?(?::(\d{2}))?\)/i);
  if (!m || monthIndex(m[1]) < 0) return { deadline: null, deadlineText: text.match(/(?:submit a request|register|sign up)\s+by\s+([^\n]+?)\.?\s*(?:\n|$)/i)?.[1] || null };
  const [, mon, day, hh, mm, ampm, zone, offH, offM] = m;
  const deadlineText = `${mon} ${day} ${hh}:${mm || "00"} ${/^p/i.test(ampm) ? "PM" : "AM"}`;
  if (zone && !/^(GMT|UTC)$/i.test(zone)) return { deadline: null, deadlineText }; // named zone we can't convert safely
  let hour = +hh % 12; if (/^p/i.test(ampm)) hour += 12;
  const offsetMin = offH ? (Math.abs(+offH) * 60 + +(offM || 0)) * (offH.startsWith("-") ? -1 : 1) : 0;
  const month = monthIndex(mon);
  let year = startDate ? +startDate.slice(0, 4) : new Date().getUTCFullYear();
  if (startDate && month > +startDate.slice(5, 7) - 1 + 6) year -= 1; // deadline in Dec for an event in Jan
  const ts = Date.UTC(year, month, +day, hour, +(mm || 0)) - offsetMin * MIN;
  return { deadline: new Date(ts).toISOString(), deadlineText };
}

function parseStatus(text, buttons, deadline) {
  const canAct = buttons.some((b) => /^(request|register|sign up|book|reserve)\b/i.test(b));
  const canWaitlist = buttons.some((b) => /waitlist/i.test(b));
  if (/registration (is )?full|waitlist (is )?full|fully booked/i.test(text)) return "full";
  if (/registration (is |has )?closed|no longer accepting|has ended/i.test(text)) return "closed";
  if (canAct) return "open";
  if (canWaitlist) return "waitlist";
  if (deadline && Date.parse(deadline) < Date.now()) return "closed";
  return "unknown";
}

const shortDates = (d) => d ? d.replace(/,\s*\d{4}$/, "").replace(/([A-Z][a-z]{2})[a-z]*/g, "$1").replace(/\s*[-–]\s*/, "–") : "dates TBA";
const STATUS_LABEL = { open: "OPEN", waitlist: "waitlist open", full: "full", closed: "closed", unknown: "changed — take a look" };
function fmtDeadline(iso) {
  if (!iso) return null;
  try {
    return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: TIMEZONE, timeZoneName: "short" }).format(new Date(iso));
  } catch { return null; }
}

// ── Reading Apple's pages ───────────────────────────────────────────────────

async function settledText(page) {
  // The page is a client-rendered app that never goes network-idle, so wait for its text to stop changing.
  await page.waitForFunction(() => (document.querySelector("main") || document.body).innerText.trim().length > 300, null, { timeout: 30_000 });
  let last = -1, stable = 0;
  for (let i = 0; i < 12 && stable < 2; i++) {
    await page.waitForTimeout(1000);
    const len = await page.evaluate(() => (document.querySelector("main") || document.body).innerText.length);
    stable = len === last ? stable + 1 : 0;
    last = len;
  }
  const root = (await page.locator("main").count()) ? page.locator("main").first() : page.locator("body");
  return (await root.innerText()).replace(/[ \t]+\n/g, "\n").replace(/\n{2,}/g, "\n").trim();
}

async function readListing(page) {
  await page.goto(LISTING, { waitUntil: "domcontentloaded", timeout: 45_000 });
  await page.waitForSelector(EVENT_LINKS, { timeout: 30_000 });
  let count = 0;
  for (let i = 0; i < 10; i++) { // scroll until no more events load
    await page.mouse.wheel(0, 5000);
    await page.waitForTimeout(700);
    const n = await page.locator(EVENT_LINKS).count();
    if (n === count && i >= 3) break;
    count = n;
  }
  const cards = await page.$$eval(EVENT_LINKS, (as) => as.map((a) => ({ href: a.href, text: a.innerText.replace(/\s+/g, " ").trim().slice(0, 300) })));
  const byId = new Map();
  for (const c of cards) {
    const id = c.href.match(/\/view\/([A-Za-z0-9]+)\/dashboard/)?.[1];
    if (id && !byId.has(id)) byId.set(id, { id, text: c.text });
  }
  if (!byId.size) throw new Error("schedule page loaded without any events");
  return [...byId.values()];
}

async function readEventOnce(page, card) {
  const url = `${BASE}/events/view/${card.id}/dashboard`;
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45_000 });
  const text = await settledText(page);
  const buttons = await page.$$eval("main button, main a.button, main [role=button]", (bs) => bs.map((b) => b.innerText.trim()).filter((t) => t && t.length < 40));
  const when = parseDates(card.text);
  const due = parseDeadline(text, when.startDate);
  const title = text.split("\n")[0].slice(0, 80);
  if (!MATCH.test(text)) throw new Error(`event page ${card.id} rendered unexpected content`);
  return { id: card.id, url, title, ...when, ...due, status: parseStatus(text, buttons, due.deadline),
    format: /online/i.test(card.text) ? "Online" : /in-person/i.test(card.text) ? "In person" : null };
}

async function readEvent(page, card) {
  let ev = await readEventOnce(page, card);
  // "Open" triggers an urgent alert and "unknown" a puzzling one, so confirm both with a second load.
  if (ev.status === "open" || ev.status === "waitlist" || ev.status === "unknown") {
    await page.waitForTimeout(3000);
    const again = await readEventOnce(page, card);
    if (again.status !== ev.status) {
      log(`event ${card.id}: first read said ${ev.status}, second said ${again.status}; reading once more`);
      await page.waitForTimeout(3000);
      ev = await readEventOnce(page, card);
      if (ev.status !== again.status) throw new Error(`event ${card.id} status is unstable (${ev.status}/${again.status})`);
    }
  }
  return ev;
}

async function scrape() {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : { channel: "chrome" }) });
  try {
    // UTC so Apple prints deadlines the same way everywhere; they're converted for display later.
    const context = await browser.newContext({ timezoneId: "UTC", locale: "en-US", viewport: { width: 1280, height: 1600 } });
    const page = await context.newPage();
    const cards = await readListing(page);
    const wanted = cards.filter((c) => MATCH.test(c.text));
    log(`schedule: ${cards.length} events listed, ${wanted.length} App Review`);
    const events = [];
    for (const card of wanted) events.push(await readEvent(page, card));
    return events;
  } finally {
    await browser.close().catch(() => {});
  }
}

async function scrapeWithRetry() {
  let lastErr;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try { return await scrape(); }
    catch (e) {
      lastErr = e;
      log(`attempt ${attempt}/3 failed: ${e.message.split("\n")[0]}`);
      if (attempt < 3) await sleep(attempt * 8000);
    }
  }
  throw lastErr;
}

// ── One full check ──────────────────────────────────────────────────────────

async function checkApple(state) {
  const now = new Date().toISOString();
  state.lastAttempt = now;
  let found;
  try {
    found = await scrapeWithRetry();
  } catch (e) {
    state.errorCount = (state.errorCount || 0) + 1;
    state.lastError = e.message.split("\n")[0].slice(0, 200);
    log(`CHECK FAILED (${state.errorCount} in a row): ${state.lastError}`);
    if (state.errorCount === ERRORS_BEFORE_ALERT) {
      await notify("App Review watcher is failing", `${ERRORS_BEFORE_ALERT} checks in a row couldn't read Apple's page. It keeps retrying.`, { priority: 3, tags: ["warning"] });
    }
    saveState(state);
    await heartbeat(false);
    return false;
  }

  const alerts = [];
  const events = {};
  for (const ev of found) {
    const prev = state.events[ev.id];
    const isNew = !state.seenEvents[ev.id];
    ev.firstSeen = state.seenEvents[ev.id] || now;
    ev.statusSince = prev && prev.status === ev.status ? prev.statusSince || now : now;
    state.seenEvents[ev.id] = ev.firstSeen;
    events[ev.id] = ev;
    log(`event ${ev.id}: ${ev.dates} status=${ev.status} deadline=${ev.deadline || ev.deadlineText || "-"}`);
    if (!state.initialized) continue; // very first run: record what's there without alerting

    const when = shortDates(ev.dates);
    const closes = fmtDeadline(ev.deadline);
    const actionable = ev.status === "open" || ev.status === "waitlist";
    if (isNew) {
      alerts.push({ key: `new:${ev.id}`, kind: actionable ? "open" : "new", eventId: ev.id, url: ev.url, time: now,
        title: actionable ? "New App Review appointment — OPEN" : "New App Review appointment posted",
        message: `${when} · ${STATUS_LABEL[ev.status]}${closes && actionable ? ` · request by ${closes}` : ""}`,
        priority: 5 });
    } else if (prev && prev.status !== ev.status) {
      alerts.push({ key: `status:${ev.id}:${ev.status}`, kind: actionable ? "open" : "status", eventId: ev.id, url: ev.url, time: now,
        title: actionable ? "App Review slots are OPEN" : `App Review ${when} is now ${STATUS_LABEL[ev.status]}`,
        message: actionable ? `${when} just opened up${closes ? ` · request by ${closes}` : ""}` : `Was ${STATUS_LABEL[prev.status] || prev.status}.`,
        priority: actionable ? 5 : ev.status === "unknown" ? 4 : 2 });
    }
  }

  for (const a of alerts) {
    const { priority, ...stored } = a;
    await notify(a.title, a.message, { url: a.url, priority, tags: a.kind === "open" ? ["rotating_light"] : ["calendar"] });
    state.alerts.unshift(stored);
  }
  if (state.errorCount >= ERRORS_BEFORE_ALERT) await notify("App Review watcher recovered", "Checks are working again.", { priority: 2, tags: ["white_check_mark"] });

  state.events = events;
  state.alerts = state.alerts.slice(0, 20);
  state.initialized = true;
  state.source = CLOUD ? "cloud" : "mac";
  state.lastCheck = now;
  state.lastError = null;
  state.errorCount = 0;
  saveState(state);
  await heartbeat(true);
  return true;
}

// ── Mac: mirror the cloud's results ─────────────────────────────────────────

async function fetchCloudState() {
  if (!REPO) return null;
  const tries = [
    [`https://api.github.com/repos/${REPO}/contents/state.json?ref=state`, { Accept: "application/vnd.github.raw+json", "User-Agent": "app-review-watcher" }],
    [`https://raw.githubusercontent.com/${REPO}/state/state.json`, {}],
  ];
  for (const [url, headers] of tries) {
    try {
      const res = await fetch(url, { headers, signal: AbortSignal.timeout(12_000) });
      if (res.ok) { const s = await res.json(); if (s && s.version === 2) return normalize(s); }
    } catch { /* offline or rate-limited: try the next source */ }
  }
  return null;
}

async function syncFromCloud(state) {
  const remote = await fetchCloudState();
  const local = (state.local ||= {});
  const cloudSeen = remote?.lastAttempt || remote?.lastCheck;
  if (!remote) { log("cloud: state not reachable"); return; }

  // Banner for anything the cloud alerted about that this Mac hasn't shown yet.
  const known = (a) => state.alerts.some((b) => b.key === a.key && Math.abs(Date.parse(b.time) - Date.parse(a.time)) < 6 * 60 * MIN);
  const fresh = remote.alerts.filter((a) => !known(a));
  for (const a of fresh.slice().reverse()) {
    if (Date.now() - Date.parse(a.time) < 3 * 60 * MIN) banner(a.title, a.message);
    log("cloud alert:", a.title, "—", a.message);
  }
  state.alerts = [...fresh, ...state.alerts].sort((a, b) => Date.parse(b.time) - Date.parse(a.time)).slice(0, 20);
  state.seenEvents = { ...remote.seenEvents, ...state.seenEvents };

  // Take the cloud's view of the schedule whenever it is at least as recent as ours.
  if (remote.lastCheck && (!state.lastCheck || Date.parse(remote.lastCheck) >= Date.parse(state.lastCheck))) {
    Object.assign(state, { events: remote.events, lastCheck: remote.lastCheck, lastAttempt: remote.lastAttempt,
      lastError: null, errorCount: 0, source: "cloud", initialized: state.initialized || remote.initialized });
  }
  state.cloud = { lastCheck: remote.lastCheck, lastAttempt: remote.lastAttempt, lastError: remote.lastError, errorCount: remote.errorCount };

  const silentFor = cloudSeen ? Date.now() - Date.parse(cloudSeen) : Infinity;
  if (silentFor > CLOUD_DOWN_MS && !local.cloudDownWarned) {
    local.cloudDownWarned = true;
    await notify("App Review cloud watcher has gone quiet", `No check from GitHub for ${Math.round(silentFor / MIN)} min. Your Mac is covering while it's awake.`, { priority: 3, tags: ["warning"] });
  } else if (silentFor < CLOUD_FRESH_MS) {
    local.cloudDownWarned = false;
  }
  log(`cloud: last check ${remote.lastCheck ? Math.round((Date.now() - Date.parse(remote.lastCheck)) / MIN) + " min ago" : "never"}, ${fresh.length} new alert(s)`);
}

async function online() {
  try { await fetch(`${BASE}/robots.txt`, { method: "HEAD", signal: AbortSignal.timeout(10_000) }); return true; }
  catch { return false; }
}

// ── Housekeeping ────────────────────────────────────────────────────────────

function acquireLock() {
  try {
    const held = readJSON(LOCK_FILE);
    if (held && Date.now() - held.time < 6 * MIN) {
      try { process.kill(held.pid, 0); return false; } catch { /* owner is gone */ }
    }
    fs.writeFileSync(LOCK_FILE, JSON.stringify({ pid: process.pid, time: Date.now() }));
    return true;
  } catch { return true; }
}
const releaseLock = () => { try { fs.unlinkSync(LOCK_FILE); } catch {} };

function trimLog() {
  try {
    if (!CLOUD && fs.statSync(LOG_FILE).size > 512 * 1024) {
      const tail = fs.readFileSync(LOG_FILE, "utf8").slice(-128 * 1024);
      fs.writeFileSync(LOG_FILE, tail.slice(tail.indexOf("\n") + 1));
    }
  } catch {}
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  if (ARGS.has("--test-notify")) {
    const sent = await push("App Review watcher: test alert", "Phone alerts are working. You'll get one like this when an appointment opens.", { url: LISTING, priority: 4, tags: ["white_check_mark"] });
    banner("App Review watcher: test alert", sent ? "Sent to your phone too." : "Phone alerts aren't set up yet.");
    log(sent ? "test alert sent" : NTFY_TOPIC ? "test alert could not be sent" : "no ntfy topic configured");
    process.exitCode = sent ? 0 : 2;
    return;
  }

  trimLog();
  if (!acquireLock()) { log("another check is already running; skipping"); return; }
  try {
    const state = loadState();
    if (CLOUD) {
      const ok = await checkApple(state);
      // One flaky run is normal; only fail the workflow (which emails the repo owner) when it's persistent.
      if (!ok && state.errorCount >= ERRORS_BEFORE_ALERT) process.exitCode = 1;
      return;
    }
    await syncFromCloud(state);
    const age = state.lastCheck ? Date.now() - Date.parse(state.lastCheck) : Infinity;
    // With a cloud watcher configured the Mac is only a fallback; without one it is the watcher.
    const maxAge = REPO ? CLOUD_FRESH_MS : 9 * MIN;
    if (ARGS.has("--force") || age > maxAge) {
      log(ARGS.has("--force") ? "checking Apple from this Mac (requested)" : `no fresh result for ${Number.isFinite(age) ? Math.round(age / MIN) + " min" : "ever"}; checking Apple from this Mac`);
      if (!(await online())) { log("this Mac is offline; skipping"); saveState(state); return; }
      const ok = await checkApple(state);
      if (!ok) process.exitCode = 1;
    } else {
      saveState(state);
    }
  } finally {
    releaseLock();
  }
}

main().catch((e) => { log("FATAL:", e.stack || e.message); releaseLock(); process.exitCode = 1; });
