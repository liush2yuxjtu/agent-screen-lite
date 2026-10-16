import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { callNative, resetDaemonForTests, stopDaemonForTests, nativePaths } from "../src/native.ts";
import { startMockHelper } from "./mock-helper.ts";

test("unix socket JSON-line IPC preserves method names and compact params", async (t) => {
  const helper = await startMockHelper((request) => {
    if (request.method === "status") {
      return { ok: true, result: { api_available: true, virtual_screens: [] } };
    }
    if (request.method === "create") {
      return { ok: true, result: { name: request.params.name, created: true } };
    }
    return { ok: false, error: { code: 90, message: `unknown method: ${request.method}` } };
  });
  t.after(() => helper.close());

  process.env.AGENT_SCREEN_SOCKET = helper.socketPath;
  process.env.AGENT_SCREEN_BINARY = path.join(os.tmpdir(), "missing-AgentScreenLite");
  resetDaemonForTests();

  const status = await callNative("status");
  assert.deepEqual(status, { api_available: true, virtual_screens: [] });

  const created = await callNative("create", { name: "Codex", width: 1920 });
  assert.deepEqual(created, { name: "Codex", created: true });

  assert.deepEqual(helper.requests, [
    { method: "status", params: {} },
    { method: "create", params: { name: "Codex", width: 1920 } },
  ]);
  assert.equal(nativePaths().socketPath, helper.socketPath);
});

test("native ok:false becomes the helper error message", async (t) => {
  const helper = await startMockHelper(() => ({
    ok: false,
    error: { code: 40, message: "target virtual screen not found" },
  }));
  t.after(() => helper.close());
  process.env.AGENT_SCREEN_SOCKET = helper.socketPath;
  process.env.AGENT_SCREEN_BINARY = path.join(os.tmpdir(), "missing-AgentScreenLite");
  resetDaemonForTests();

  await assert.rejects(() => callNative("move_app", { bundle_id: "com.apple.Calculator" }), {
    message: "target virtual screen not found",
  });
});

test("spawns the native helper with --daemon and AGENT_SCREEN_SOCKET", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "asl-spawn-"));
  const binary = path.join(dir, "AgentScreenLite");
  const marker = path.join(dir, "spawn.json");
  const socketPath = path.join(dir, "control.sock");
  fs.writeFileSync(
    binary,
    `#!/usr/bin/env node
const fs = require("node:fs");
const net = require("node:net");
fs.writeFileSync(process.env.SPAWN_MARKER, JSON.stringify({
  argv: process.argv.slice(2),
  socket: process.env.AGENT_SCREEN_SOCKET,
}));
const server = net.createServer((socket) => {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.includes(10)) {
      socket.write(JSON.stringify({ ok: true, result: { spawned: true } }) + "\\n");
    }
  });
});
server.listen(process.env.AGENT_SCREEN_SOCKET);
`,
    { mode: 0o755 },
  );

  process.env.AGENT_SCREEN_BINARY = binary;
  process.env.AGENT_SCREEN_SOCKET = socketPath;
  process.env.SPAWN_MARKER = marker;
  resetDaemonForTests();
  t.after(() => {
    stopDaemonForTests();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  const result = await callNative("status");
  assert.deepEqual(result, { spawned: true });
  const recorded = JSON.parse(fs.readFileSync(marker, "utf8")) as {
    argv: string[];
    socket: string;
  };
  assert.deepEqual(recorded.argv, ["--daemon"]);
  assert.equal(recorded.socket, socketPath);
});

test("missing helper binary matches the Python error", async () => {
  const missingSocket = path.join(os.tmpdir(), `asl-missing-${process.pid}.sock`);
  try {
    fs.unlinkSync(missingSocket);
  } catch {
    // Expected when the path is unused.
  }
  const missingBinary = path.join(os.tmpdir(), "definitely-missing-AgentScreenLite");
  process.env.AGENT_SCREEN_SOCKET = missingSocket;
  process.env.AGENT_SCREEN_BINARY = missingBinary;
  resetDaemonForTests();

  await assert.rejects(() => callNative("status"), {
    message: `native helper is missing: ${missingBinary}`,
  });
});
