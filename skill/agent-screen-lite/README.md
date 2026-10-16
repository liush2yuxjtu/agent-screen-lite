# agent-screen-lite

A small local MCP + native macOS helper inspired by yomado. It removes the control panel and exposes only a reversible virtual-screen lifecycle:

`status → create → move_app → verify/capture → restore → destroy`

The native helper reuses the MIT-licensed `VDVirtualDisplay` and `YMAppWorkspace` implementation from [chekusu/yomado](https://github.com/chekusu/yomado), with attribution retained in `LICENSE`. It still uses private macOS `CGVirtualDisplay` APIs and must be built and run on Apple Silicon macOS in an unlocked graphical login session.

## Build on macOS

```bash
./build.sh
```

The build needs only Xcode or Command Line Tools. It produces `dist/AgentScreenLite`, an ad-hoc signed local executable.

## Run the MCP server

The TypeScript MCP server lives in `mcp-server/`. Install, build, then configure a local MCP entry using the included `plugin/mcp.json` or run it directly:

```bash
npm --prefix mcp-server install
npm --prefix mcp-server run build
AGENT_SCREEN_ROOT="$PWD" node mcp-server/dist/index.js
```

The first tool call starts the native helper and creates a user-only Unix socket at `~/Library/Application Support/agent-screen-lite/control.sock`.

## Boundary

This is a work-screen manager. It does not provide a second input session, a remote desktop, or a screenshot/input agent. A real end-to-end acceptance test must use a logged-in macOS session, grant Accessibility to the native helper and Screen Recording to the capture caller, move a harmless running app, capture the target display, perform one reversible input action through an authorized computer-use tool, then restore and destroy the screen.
