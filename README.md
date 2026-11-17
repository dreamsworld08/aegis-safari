# Aegis — AI Sidebar Agent for Safari

A bring-your-own-model AI sidebar and browsing agent for Safari on Apple Silicon Macs. Ask about the current page or all your tabs, or let it act (open, switch, navigate, click, type, close) — every action that changes something needs your approval.

## Features

- **Sidebar** on any page (toolbar button or `⌘⇧K`), streaming answers, per-tab chat history.
- **Agent tools**: `list_tabs`, `read_page`, `switch_tab`, `open_tab`, `navigate`, `click`, `type_text`, `scroll`, `close_tab`.
- **Any model**:
  - Anthropic Claude (native Messages API)
  - Any OpenAI-compatible API: OpenAI, DeepSeek, Qwen (DashScope), Google Gemini, GitHub Models (Copilot accounts), OpenRouter
  - Local open-weight models on Apple Silicon: Ollama, LM Studio, `mlx_lm.server`
  - The model must support tool/function calling to use the agent tools.
- **Mac-native**: arm64-only Release build, keys in the macOS Keychain via the Swift app extension, no bundler or runtime dependencies, a non-persistent background script, and system font plus light/dark mode.

## Security model

| Control | Behaviour |
|---|---|
| Approval gate | `open_tab`, `navigate`, `click`, `type_text`, `close_tab` need **Allow once** / **Allow on site (session)** / **Deny**. |
| Domain blocklist | Banks, payment, identity and password-manager domains are never readable or controllable; you can add more in Settings. |
| Sensitive fields | Password, card, CVV and OTP fields are never typed into, and their values are never read. |
| Prompt injection | Page text is wrapped as `<untrusted_page_content>`, the system prompt says to treat it as data, and a heuristic flags injection phrases. |
| URL policy | Only `http(s)` navigation. Model endpoints must be `https` (`http` is allowed only for localhost). |
| Secrets | API keys go to the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and are never sent to page or sidebar contexts. |
| Audit log | Every tool call (typed text redacted) is logged locally. You can view and clear it in Settings. |
| No telemetry | Network traffic goes only to the model endpoint you configure. |

## Build & install (macOS 14+, Xcode 15+, Apple Silicon)

```bash
git clone https://github.com/dreamsworld08/aegis-safari.git
```

```bash
cd aegis-safari && ./scripts/build-safari.sh
```

1. Open the built `Aegis.app` once.
2. Safari ▸ Settings ▸ Advanced ▸ enable **Show features for web developers**. Then Develop ▸ **Allow Unsigned Extensions** (only needed for local unsigned builds).
3. Safari ▸ Settings ▸ Extensions ▸ enable **Aegis**, and allow it on **All Websites**.
4. Click the Aegis toolbar icon ▸ ⚙︎ ▸ add a model and its key.

To distribute it, sign with your Developer ID: `SIGN_ARGS="CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=XXXXXXXXXX" ./scripts/build-safari.sh`, then notarize.

### Local model example (fully offline)

```bash
pip install mlx-lm
```

```bash
mlx_lm.server --model mlx-community/Qwen3-14B-4bit --port 8080
```

Then pick the **mlx_lm.server (Apple Silicon)** preset. For Ollama: `ollama pull qwen3:14b` and pick the **Ollama** preset.

## Layout

```
extension/   Web extension (manifest v3): background.js (agent, providers, policy), content.js (sidebar + DOM tools), sidebar.*, options.*
native/      Swift Keychain bridge, copied into the generated Xcode project
scripts/     build-safari.sh (converter + arm64 xcodebuild), check.mjs (CI checks)
```

## Limits

- Safari blocks extensions on Apple pages, the Start Page and other extensions' pages. On those pages the sidebar opens in a tab.
- Tabs that were open before you installed Aegis get the script injected on first use. If that fails, reload the tab.
- Cross-origin iframes are not read.

MIT licensed.
