"use strict";
const $ = (id) => document.getElementById(id);
const post = (m) => webkit.messageHandlers.controller.postMessage(m);

function show(s) {
  $("version").textContent = s.version;
  $("state").textContent = s.enabled
    ? "Aegis is enabled in Safari."
    : "Aegis is off. Turn it on in Safari ▸ Settings ▸ Extensions.";
}

function updateStatus(s) {
  $("err").textContent = "";
  $("install").hidden = s.state !== "available";
  $("check").disabled = s.state === "checking" || s.state === "installing" || s.state === "relaunching";
  switch (s.state) {
    case "checking": $("upd").textContent = "Checking for updates…"; break;
    case "current": $("upd").textContent = "You're up to date."; break;
    case "available": $("upd").textContent = `Version ${s.latest} is available.`; break;
    case "installing": $("upd").textContent = `Downloading and verifying ${s.latest}…`; break;
    case "relaunching": $("upd").textContent = `Installed ${s.latest}. Relaunching…`; break;
    case "error": $("upd").textContent = "Update failed."; $("err").textContent = s.message || ""; break;
  }
}

$("prefs").addEventListener("click", () => post("open-preferences"));
$("check").addEventListener("click", () => post("check-update"));
$("install").addEventListener("click", () => post("install-update"));
