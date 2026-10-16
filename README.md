# Agent Screen Lite

Experimental local macOS virtual-display helper with a TypeScript stdio MCP server and agent skill source.

## Requirements and build

- Apple Silicon Mac with an unlocked graphical login session.
- Xcode or Command Line Tools, and Node.js 18+.
- macOS Accessibility and screen-capture permission for the executing components.
- Uses private CGVirtualDisplay APIs; OS compatibility is not guaranteed.

From the repository root:

```sh
./build.sh
npm --prefix mcp-server install
npm --prefix mcp-server run build
node mcp-server/dist/index.js
```

The MCP server reads JSON-RPC from stdin; it is not an interactive terminal UI. The first tool call starts the persistent native helper. Native ObjC sources stay in `native/` and still build with `./build.sh`.

Configure your MCP client to launch `node` with the absolute path to `mcp-server/dist/index.js`. The project root is inferred from the compiled entrypoint; `AGENT_SCREEN_ROOT` can override it.

## Tools

`screen_status`, `screen_create`, `screen_move_app`, `screen_capture`, `screen_verify`, `screen_restore`, `screen_destroy`.

The native helper owns virtual displays, moves running app windows through Accessibility, and writes PNG captures locally. The MCP returns capture paths, not inline image content. Actual mouse and keyboard operation needs a separate authorized computer-use tool.

`skill/agent-screen-lite/SKILL.md` contains agent workflow instructions. `plugin/` contains draft integration files, not a complete installed plugin.

## Verification status

Historical device tests used an Apple M4 Mac mini running macOS 15.3.1:
- Native compilation and ad-hoc code-sign verification passed.
- MCP initialization and listing seven tools passed.
- Two named virtual displays were created.
- Calculator moved from virtual display A to B and back to A; native window inventory confirmed the moves.
- A PNG capture was created and its 1280 × 720 dimensions verified. Its pixels were not visually reviewed.
- A move with only one online display was refused.

These tests do **not** prove exact checkpoint restoration onto a physical display, a complete restore/destroy lifecycle with occupied screens, mouse/keyboard execution, independent input, locked-session operation, or unattended reliability. Headless topology prevented the physical-display recovery test. Test displays were removed after returning and quitting the disposable Calculator test app.

## Limits

Virtual displays share the login session's focus, keyboard and pointer. They do not provide independent human/agent input sessions. A first virtual display may replace a headless fallback display, changing the desktop topology. Keep physical displays active during normal use.

Window checkpoints are held in memory. Leave the helper running when recovery fails. Generic WeChat window movement is blocked; its dedicated recovery handler is not included.

This is a prototype. Daemon startup/retry behavior, concurrent clients and crash recovery still need further validation before unattended use.

## Attribution

MIT licensed. Native display and workspace code is adapted from [chekusu/yomado](https://github.com/chekusu/yomado), upstream revision `0513b90979c348f234579b74d7b41abbaac238fd`. The original license is retained in LICENSE. Local modifications add a socket daemon/MCP interface and scope display ownership to this helper.
