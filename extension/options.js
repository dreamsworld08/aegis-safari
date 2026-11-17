"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
const send = (m) => api.runtime.sendMessage(m);
let state = null, editingId = null;

function fill(p) {
  $("name").value = p.name || ""; $("kind").value = p.kind || "openai";
  $("baseUrl").value = p.baseUrl || ""; $("model").value = p.model || "";
  $("local").checked = !!p.local; $("key").value = "";
}

async function load() {
  state = await send({ type: "getState" });
  const tb = $("providers"); tb.textContent = "";
  for (const p of state.providers) {
    const tr = document.createElement("tr");
    const cells = [p.name + (p.id === state.activeId ? " ✓" : ""), p.model, p.baseUrl, state.hasKey[p.id] ? "saved" : (p.local ? "local" : "missing")];
    for (const c of cells) { const td = document.createElement("td"); td.textContent = c; tr.append(td); }
    const td = document.createElement("td");
    for (const [label, fn] of [["Use", () => send({ type: "setActive", id: p.id }).then(load)], ["Edit", () => { editingId = p.id; fill(p); $("formTitle").textContent = "Edit " + p.name; }], ["Delete", () => confirm("Delete " + p.name + "?") && send({ type: "deleteProvider", id: p.id }).then(load)]]) {
      const b = document.createElement("button"); b.textContent = label; b.onclick = fn; td.append(b, " ");
    }
    tr.append(td); tb.append(tr);
  }
  if (!state.providers.length) tb.innerHTML = '<tr><td colspan="5" class="muted">No models yet — pick a preset below.</td></tr>';
  if (!$("preset").options.length) {
    state.presets.forEach((p, i) => { const o = document.createElement("option"); o.value = i; o.textContent = p.name; $("preset").append(o); });
    fill(state.presets[0]);
  }
  $("defaults").textContent = state.defaultBlocklist.join(", ");
  $("blocklist").value = (state.blocklist || []).join("\n");
  $("maxSteps").value = state.maxSteps;
}

$("preset").onchange = () => { editingId = null; $("formTitle").textContent = "Add a model"; fill(state.presets[$("preset").value]); };
$("reset").onclick = () => { editingId = null; $("formTitle").textContent = "Add a model"; fill(state.presets[$("preset").value]); };
$("save").onclick = async () => {
  const provider = { id: editingId, name: $("name").value.trim(), kind: $("kind").value, baseUrl: $("baseUrl").value.trim(), model: $("model").value.trim(), local: $("local").checked };
  if (!provider.name || !provider.baseUrl || !provider.model) { $("status").textContent = "Name, base URL and model are required."; return; }
  try { const u = new URL(provider.baseUrl); if (u.protocol !== "https:" && !/^(localhost|127\.0\.0\.1|\[::1\])$/.test(u.hostname)) throw 0; }
  catch (_) { $("status").textContent = "Base URL must be https (or http://localhost for local models)."; return; }
  const r = await send({ type: "saveProvider", provider, apiKey: $("key").value });
  $("status").textContent = r.keyStoredIn === "keychain" ? "Saved. Key stored in macOS Keychain." : r.keyStoredIn === "storage" ? "Saved. Key stored in extension storage (Keychain bridge unavailable)." : "Saved.";
  editingId = null; $("key").value = ""; load();
};
$("savePolicy").onclick = async () => {
  await send({ type: "saveSettings", blocklist: $("blocklist").value.split("\n"), maxSteps: Number($("maxSteps").value) });
  load();
};
async function loadAudit() {
  const log = await send({ type: "getAudit" });
  $("audit").textContent = log.slice().reverse().map((e) => `${new Date(e.t).toLocaleString()}  ${e.model}  ${e.tool} ${JSON.stringify(e.args)}\n    → ${e.result}`).join("\n") || "Empty.";
}
$("refreshAudit").onclick = loadAudit;
$("clearAudit").onclick = () => send({ type: "clearAudit" }).then(loadAudit);
load(); loadAudit();
