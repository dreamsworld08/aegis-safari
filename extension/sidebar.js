"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
let tabId = parseInt(params.get("tab"), 10);
let port = null, running = false, history = [], aiEl = null, aiText = "";

const histKey = () => "aegis:h:" + tabId;
function loadHistory() { try { history = JSON.parse(sessionStorage.getItem(histKey()) || "[]"); } catch (_) { history = []; } }
function saveHistory() { try { sessionStorage.setItem(histKey(), JSON.stringify(history)); } catch (_) {} }

/* Minimal, safe markdown: escape first, then format. */
function esc(s) { return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function md(src) {
  const parts = src.split(/```/);
  return parts.map((p, i) => {
    if (i % 2) return "<pre><code>" + esc(p.replace(/^[a-z0-9+-]*\n/i, "")) + "</code></pre>";
    return esc(p)
      .replace(/`([^`\n]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
      .replace(/^#{1,6} (.+)$/gm, "<strong>$1</strong>")
      .replace(/^[-*] (.+)$/gm, "• $1")
      .replace(/\n/g, "<br>");
  }).join("");
}

function add(cls, html) {
  const hint = document.querySelector(".hint"); if (hint) hint.remove();
  const d = document.createElement("div");
  d.className = cls; d.innerHTML = html;
  $("log").append(d); $("log").scrollTop = $("log").scrollHeight;
  return d;
}
function renderHistory() {
  for (const m of history) {
    if (m.role === "user") add("msg user", esc(m.content.replace(/^\[[^\]]*\]\n/, "")));
    else if (m.role === "assistant" && m.content) add("msg ai", md(m.content));
  }
}

function setRunning(v) { running = v; $("send").textContent = v ? "Stop" : "Send"; }

function connect() {
  port = api.runtime.connect({ name: "aegis-agent" });
  port.onDisconnect.addListener(() => { port = null; if (running) { add("msg err", "Connection lost."); setRunning(false); } });
  port.onMessage.addListener((m) => {
    switch (m.type) {
      case "text":
        if (!aiEl) { aiEl = add("msg ai", ""); aiText = ""; }
        aiText += m.delta; aiEl.innerHTML = md(aiText); $("log").scrollTop = $("log").scrollHeight;
        break;
      case "text_break": aiEl = null; break;
      case "tool": aiEl = null; add("tool", esc(`▸ ${m.name} ${JSON.stringify(m.args)}`)); break;
      case "tool_result": add("tool", esc("  ↳ " + m.summary.split("\n")[0])); break;
      case "approval": showApproval(m); break;
      case "done": history = m.messages; saveHistory(); aiEl = null; setRunning(false); break;
      case "error": aiEl = null; add("msg err", esc(m.message)); setRunning(false); break;
    }
  });
}

function showApproval(m) {
  const card = add("approval", `<strong>Approve: ${esc(m.title)}</strong><div class="detail">${esc(m.detail || "")}</div>
    <div class="row"><button class="primary" data-d="once">Allow once</button><button data-d="site">Allow on ${esc(new URL(m.origin || "about:blank").host || "this site")} (session)</button><button data-d="deny">Deny</button></div>`);
  card.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
    if (port) port.postMessage({ type: "approval", id: m.id, decision: b.dataset.d });
    card.querySelector(".row").textContent = b.dataset.d === "deny" ? "Denied" : "Approved";
  }));
}

function send(text) {
  if (!port) connect();
  add("msg user", esc(text));
  setRunning(true);
  aiEl = null;
  port.postMessage({ type: "run", text, tabId, history });
}

$("form").addEventListener("submit", (e) => {
  e.preventDefault();
  if (running) { if (port) port.postMessage({ type: "stop" }); return; }
  const t = $("input").value.trim();
  if (!t) return;
  $("input").value = "";
  send(t);
});
$("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); $("form").requestSubmit(); }
});
$("close").addEventListener("click", () => params.get("mode") === "tab" ? window.close() : parent.postMessage({ aegis: "close" }, "*"));
$("settings").addEventListener("click", () => api.runtime.openOptionsPage());
$("clear").addEventListener("click", () => {
  if (running) return;
  history = []; saveHistory(); $("log").innerHTML = '<div class="hint">New chat.</div>';
  if (port) { port.disconnect(); port = null; }
});
$("model").addEventListener("change", (e) => api.runtime.sendMessage({ type: "setActive", id: e.target.value }));

(async function init() {
  if (!Number.isInteger(tabId)) {
    const [t] = await api.tabs.query({ active: true, currentWindow: true });
    tabId = t ? t.id : -1;
  }
  const st = await api.runtime.sendMessage({ type: "getState" });
  const sel = $("model");
  if (!st.providers.length) { sel.innerHTML = "<option>No model — open settings</option>"; }
  for (const p of st.providers) {
    const o = document.createElement("option");
    o.value = p.id; o.textContent = `${p.name} · ${p.model}`; o.selected = p.id === st.activeId;
    sel.append(o);
  }
  loadHistory(); renderHistory();
  $("input").focus();
})();
