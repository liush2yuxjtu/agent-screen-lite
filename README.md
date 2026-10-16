# Agent Screen Lite — macOS virtual display MCP for AI agents

**Lightweight macOS virtual-display MCP server** so coding agents can create isolated screens, move app windows onto them, capture PNGs, and tear displays down — without taking over your physical monitor.

Built on private **CGVirtualDisplay** APIs, with a TypeScript **stdio MCP** server and an agent skill. MIT-licensed prototype.

> **Status:** Experimental. Uses private Apple APIs; OS compatibility is not guaranteed. Prefer an unlocked graphical login on Apple Silicon.

## Why / use cases

| Need | What you get |
| --- | --- |
| Give an agent its own screen | Named virtual displays via MCP (`screen_create` / `screen_destroy`) |
| Keep the physical desktop free | Move windows with Accessibility (`screen_move_app`); capture locally (`screen_capture`) |
| Computer-use workflows | Pair with a separate authorized mouse/keyboard tool; this server returns paths, not inline images |
| Local-only MCP | Stdio JSON-RPC; no cloud; project root inferred from the compiled entrypoint |

Typical flows: UI test isolation, parallel agent demos, screenshot verification of a moved window, temporary “agent desk” next to your real display.

## Demo

<!-- TODO: add a short GIF after going public — create display → move Calculator → capture PNG → destroy -->

*[Demo GIF placeholder]* Record a 10–20s loop: `screen_create` → move an app → `screen_capture` → `screen_destroy`. Host under `docs/media/` or release assets, then replace this section.

## Requirements

- Apple Silicon Mac with an unlocked graphical login session
- Xcode or Command Line Tools, and Node.js 18+
- macOS **Accessibility** and **screen-capture** permission for the executing components
- Private CGVirtualDisplay APIs — behavior can change across macOS versions

## Quick start

From the repository root:

```sh
./build.sh
npm --prefix mcp-server install
npm --prefix mcp-server run build
node mcp-server/dist/index.js
```

The MCP server reads JSON-RPC from stdin; it is not an interactive terminal UI. The first tool call starts the persistent native helper. Native ObjC sources live in `native/` and build with `./build.sh`.

Configure your MCP client to launch `node` with the **absolute path** to `mcp-server/dist/index.js`. The project root is inferred from the compiled entrypoint; set `AGENT_SCREEN_ROOT` to override.

Example MCP client snippet (paths are local to your machine):

```json
{
  "mcpServers": {
    "agent-screen-lite": {
      "command": "node",
      "args": ["/absolute/path/to/agent-screen-lite/mcp-server/dist/index.js"]
    }
  }
}
```

## Tools

| Tool | Role |
| --- | --- |
| `screen_status` | Inspect helper / display state |
| `screen_create` | Create a named virtual display |
| `screen_move_app` | Move a running app window via Accessibility |
| `screen_capture` | Write a local PNG; returns a path |
| `screen_verify` | Verify capture dimensions / basic checks |
| `screen_restore` | Restore window checkpoints held in memory |
| `screen_destroy` | Tear down a virtual display |

The native helper owns virtual displays, moves windows, and writes PNG captures locally. The MCP returns **capture paths**, not inline image content. Actual mouse and keyboard operation needs a **separate** authorized computer-use tool.

Agent workflow instructions: `skill/agent-screen-lite/SKILL.md`.  
`plugin/` holds draft integration files (not a complete installed plugin).

## Verification status

Historical device tests used an Apple M4 Mac mini running macOS 15.3.1:

- Native compilation and ad-hoc code-sign verification passed
- MCP initialization and listing seven tools passed
- Two named virtual displays were created
- Calculator moved between virtual displays; native window inventory confirmed the moves
- A PNG capture was created and its 1280×720 dimensions verified (pixels not visually reviewed)
- A move with only one online display was refused

These tests do **not** prove exact checkpoint restoration onto a physical display, a complete restore/destroy lifecycle with occupied screens, mouse/keyboard execution, independent input, locked-session operation, or unattended reliability.

## Limits

- Virtual displays share the login session’s focus, keyboard, and pointer — not independent human/agent input sessions
- A first virtual display may replace a headless fallback display and change desktop topology; keep physical displays active during normal use
- Window checkpoints are in memory — leave the helper running when recovery fails
- Generic WeChat window movement is blocked; a dedicated recovery handler is not included
- Prototype: daemon retry, concurrent clients, and crash recovery still need validation before unattended use

## Related projects

- [pi-debug-mode](https://github.com/liush2yuxjtu/pi-debug-mode) — evidence-first Debug Mode for the Pi coding agent
- [atelier](https://github.com/liush2yuxjtu/atelier) — open-source Claude Design / Artifacts alternative

## Attribution

MIT licensed. Native display and workspace code is adapted from [chekusu/yomado](https://github.com/chekusu/yomado), upstream revision `0513b90979c348f234579b74d7b41abbaac238fd`. The original license is retained in LICENSE. Local modifications add a socket daemon/MCP interface and scope display ownership to this helper.

## License

[MIT](LICENSE)
