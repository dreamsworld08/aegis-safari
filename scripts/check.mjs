// Static checks run in CI: manifest validity, referenced files exist, JS parses.
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const dir = new URL("../extension/", import.meta.url).pathname;
const m = JSON.parse(readFileSync(dir + "manifest.json", "utf8"));
const refs = [
  ...m.background.scripts, m.options_ui.page,
  ...Object.values(m.icons), ...Object.values(m.action.default_icon),
  ...m.content_scripts.flatMap((c) => c.js), ...m.web_accessible_resources.flatMap((w) => w.resources)
];
const missing = refs.filter((f) => !existsSync(dir + f));
if (missing.length) { console.error("Missing files:", missing); process.exit(1); }
for (const f of ["background.js", "content.js", "sidebar.js", "options.js"]) execFileSync(process.execPath, ["--check", dir + f], { stdio: "inherit" });
console.log("OK:", refs.length, "manifest references, 4 scripts parsed");
