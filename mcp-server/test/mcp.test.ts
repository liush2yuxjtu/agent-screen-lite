import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { INSTRUCTIONS, SERVER_NAME, TOOL_NAMES, VERSION } from "../src/server.ts";
import { startMockHelper } from "./mock-helper.ts";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const serverEntry = path.join(repoRoot, "mcp-server", "dist", "index.js");

const EXPECTED_DESCRIPTIONS: Record<string, string> = {
  screen_status:
    "Read virtual displays, online displays, Accessibility readiness, and whether a second display is available for safe window isolation.",
  screen_create: "Create or reuse a named macOS virtual work screen. This does not move apps.",
  screen_move_app:
    "Move an already running app's ordinary windows from one source display into a named virtual screen. Defaults to physical displays only when source_display_id is omitted.",
  screen_restore:
    "Restore one app or all tracked app windows from a virtual screen to their recorded physical placement.",
  screen_verify:
    "Verify that a virtual screen is online and capturable; reports permissions and writes a local PNG evidence file. It does not claim keyboard or mouse isolation.",
  screen_capture: "Capture one virtual display to a local PNG for visual inspection.",
  screen_destroy:
    "Restore tracked windows and remove a virtual screen. Refuses to destroy when restoration cannot be verified.",
};

test("stdio MCP lists the original screen_* tools and forwards calls over the native socket", async (t) => {
  const helper = await startMockHelper((request) => {
    if (request.method === "status") {
      return {
        ok: true,
        result: { api_available: true, accessibility_trusted: false, virtual_screens: [] },
      };
    }
    if (request.method === "create") {
      return { ok: true, result: { name: request.params.name, display_id: 42, created: true } };
    }
    if (request.method === "destroy") {
      return { ok: false, error: { message: "virtual screen not found" } };
    }
    return { ok: false, error: { message: `unknown method: ${request.method}` } };
  });
  t.after(() => helper.close());

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    cwd: repoRoot,
    env: {
      ...process.env,
      AGENT_SCREEN_ROOT: repoRoot,
      AGENT_SCREEN_SOCKET: helper.socketPath,
      AGENT_SCREEN_BINARY: path.join(repoRoot, "dist", "AgentScreenLite-not-used"),
    },
  });
  const client = new Client({ name: "agent-screen-lite-test", version: "0.0.0" });
  await client.connect(transport);
  t.after(async () => {
    await client.close();
  });

  assert.equal(client.getServerVersion()?.name, SERVER_NAME);
  assert.equal(client.getServerVersion()?.version, VERSION);
  assert.equal(client.getInstructions(), INSTRUCTIONS);

  const listed = await client.listTools();
  const names = listed.tools.map((tool) => tool.name);
  assert.deepEqual(names, [...TOOL_NAMES]);
  for (const tool of listed.tools) {
    assert.equal(tool.description, EXPECTED_DESCRIPTIONS[tool.name]);
  }

  const status = await client.callTool({ name: "screen_status", arguments: {} });
  assert.equal(status.isError, undefined);
  assert.deepEqual(status.structuredContent, {
    api_available: true,
    accessibility_trusted: false,
    virtual_screens: [],
  });

  const created = await client.callTool({
    name: "screen_create",
    arguments: { name: "Codex · Blender", width: 1920, height: 1080, hi_dpi: false },
  });
  assert.deepEqual(created.structuredContent, {
    name: "Codex · Blender",
    display_id: 42,
    created: true,
  });

  const failed = await client.callTool({
    name: "screen_destroy",
    arguments: { screen: "missing" },
  });
  assert.equal(failed.isError, true);
  const errorText = failed.content
    .map((item) => (item.type === "text" ? item.text : ""))
    .join("");
  assert.equal(errorText, "virtual screen not found");

  assert.deepEqual(
    helper.requests.map((request) => request.method),
    ["status", "create", "destroy"],
  );
  assert.deepEqual(helper.requests[1]?.params, {
    name: "Codex · Blender",
    width: 1920,
    height: 1080,
    hi_dpi: false,
  });
});
