"use strict";
/* Aegis content script: injects the sidebar iframe and performs DOM snapshot/actions on request. */
(() => {
  if (window.__aegisLoaded) return;
  window.__aegisLoaded = true;
  const api = globalThis.browser ?? globalThis.chrome;
  const WIDTH = 420;
  let frame = null, styleEl = null;

  /* ---------- sidebar ---------- */
  async function open() {
    if (frame) return;
    let tabId;
    try { tabId = (await api.runtime.sendMessage({ type: "whoami" })).tabId; } catch (_) {}
    frame = document.createElement("iframe");
    frame.src = api.runtime.getURL("sidebar.html?tab=" + (tabId ?? ""));
    frame.setAttribute("allow", "clipboard-write");
    frame.style.cssText = `all:initial;position:fixed;top:0;right:0;width:${WIDTH}px;height:100vh;border:0;z-index:2147483647;box-shadow:-2px 0 16px rgba(0,0,0,.25);background:#fff;color-scheme:normal`;
    styleEl = document.createElement("style");
    styleEl.textContent = `html{margin-right:${WIDTH}px !important}`;
    document.documentElement.append(styleEl, frame);
  }
  function close() {
    if (frame) { frame.remove(); frame = null; }
    if (styleEl) { styleEl.remove(); styleEl = null; }
  }
  window.addEventListener("message", (e) => {
    if (frame && e.source === frame.contentWindow && e.data && e.data.aegis === "close") close();
  });

  /* ---------- snapshot ---------- */
  const INTERACTIVE = 'a[href],button,input,select,textarea,summary,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[role="checkbox"],[contenteditable=""],[contenteditable="true"],[onclick]';
  let counter = 0;

  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
  }
  function labelOf(el) {
    const v = el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("placeholder") ||
      (el.labels && el.labels[0] && el.labels[0].innerText) || el.innerText || el.value || el.getAttribute("alt") || "";
    return String(v).replace(/\s+/g, " ").trim().slice(0, 80);
  }
  function roleOf(el) {
    return el.getAttribute("role") || (el.tagName === "INPUT" ? "input:" + (el.type || "text") : el.tagName.toLowerCase());
  }
  function isSensitive(el) {
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    const hint = ((el.name || "") + " " + (el.id || "")).toLowerCase();
    return el.type === "password" || /cc-|one-time-code|current-password|new-password/.test(ac) || /(passw|cvv|cvc|card.?num|ssn)/.test(hint);
  }

  function snapshot(maxChars) {
    const root = document.querySelector("main,article,[role=main]") || document.body;
    let text = (root.innerText || "").replace(/\n{3,}/g, "\n\n").trim();
    if (text.length < 400 && root !== document.body) text = (document.body.innerText || "").trim();
    if (text.length > maxChars) text = text.slice(0, maxChars) + "\n…[truncated]";
    const elements = [];
    for (const el of document.querySelectorAll(INTERACTIVE)) {
      if (elements.length >= 150) break;
      if (el.closest("[data-aegis-ignore]") || !visible(el)) continue;
      if (!el.dataset.aegisId) el.dataset.aegisId = String(++counter);
      const sensitive = isSensitive(el);
      elements.push({
        id: Number(el.dataset.aegisId), role: roleOf(el), label: labelOf(el),
        href: el.tagName === "A" ? el.href.slice(0, 120) : undefined,
        value: !sensitive && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && el.type !== "hidden" ? String(el.value || "").slice(0, 40) : undefined
      });
    }
    return { text, elements };
  }
  const byId = (id) => document.querySelector(`[data-aegis-id="${Number(id)}"]`);

  function setValue(el, v) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value");
    if (setter && setter.set) setter.set.call(el, v); else el.value = v;
  }

  /* ---------- message handling ---------- */
  api.runtime.onMessage.addListener((msg, _s, send) => {
    if (!msg || typeof msg.type !== "string" || !msg.type.startsWith("aegis:")) return;
    try {
      switch (msg.type) {
        case "aegis:toggle": frame ? close() : open(); send({ ok: true }); break;
        case "aegis:snapshot": send(snapshot(msg.maxChars || 20000)); break;
        case "aegis:describe": {
          const el = byId(msg.id);
          if (!el) return send({ ok: false, error: "Element not found. Re-read the page." }), undefined;
          send({ ok: true, role: roleOf(el), label: labelOf(el), sensitive: isSensitive(el) });
          break;
        }
        case "aegis:click": {
          const el = byId(msg.id);
          if (!el) return send({ ok: false, error: "Element not found. Re-read the page." }), undefined;
          el.scrollIntoView({ block: "center" });
          el.click();
          send({ ok: true });
          break;
        }
        case "aegis:type": {
          const el = byId(msg.id);
          if (!el) return send({ ok: false, error: "Element not found. Re-read the page." }), undefined;
          if (isSensitive(el)) return send({ ok: false, error: "Sensitive field refused." }), undefined;
          el.scrollIntoView({ block: "center" }); el.focus();
          if (el.isContentEditable) { el.textContent = msg.text; el.dispatchEvent(new InputEvent("input", { bubbles: true })); }
          else { setValue(el, msg.text); el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); }
          if (msg.submit) {
            if (el.form && el.form.requestSubmit) el.form.requestSubmit();
            else for (const t of ["keydown", "keypress", "keyup"]) el.dispatchEvent(new KeyboardEvent(t, { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
          }
          send({ ok: true });
          break;
        }
        case "aegis:scroll": {
          const h = window.innerHeight * 0.85;
          const d = msg.direction;
          if (d === "top") window.scrollTo({ top: 0 });
          else if (d === "bottom") window.scrollTo({ top: document.documentElement.scrollHeight });
          else window.scrollBy({ top: d === "up" ? -h : h });
          send({ ok: true });
          break;
        }
        default: send({ ok: false, error: "unknown" });
      }
    } catch (e) { send({ ok: false, error: String(e && e.message || e) }); }
    return true;
  });
})();
