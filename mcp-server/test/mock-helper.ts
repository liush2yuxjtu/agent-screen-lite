import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

export type NativeHandler = (request: {
  method: string;
  params: Record<string, unknown>;
}) => Record<string, unknown>;

export type MockHelper = {
  socketPath: string;
  requests: Array<{ method: string; params: Record<string, unknown> }>;
  close: () => Promise<void>;
};

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function startMockHelper(handler: NativeHandler): Promise<MockHelper> {
  const socketPath = path.join(
    os.tmpdir(),
    `asl-mcp-${process.pid}-${Math.random().toString(16).slice(2)}.sock`,
  );
  try {
    fs.unlinkSync(socketPath);
  } catch {
    // New path; nothing to remove.
  }

  const requests: MockHelper["requests"] = [];
  const server = net.createServer((socket) => {
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      let newline = buffer.indexOf(0x0a);
      while (newline !== -1) {
        const line = buffer.subarray(0, newline).toString("utf8");
        buffer = buffer.subarray(newline + 1);
        const parsed: unknown = JSON.parse(line);
        if (!isJsonObject(parsed) || typeof parsed.method !== "string") {
          socket.write(`${JSON.stringify({ ok: false, error: { message: "request must be a JSON object" } })}\n`);
        } else {
          const params = isJsonObject(parsed.params) ? parsed.params : {};
          requests.push({ method: parsed.method, params });
          const response = handler({ method: parsed.method, params });
          socket.write(`${JSON.stringify(response)}\n`);
        }
        newline = buffer.indexOf(0x0a);
      }
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });

  return {
    socketPath,
    requests,
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
      try {
        fs.unlinkSync(socketPath);
      } catch {
        // Socket file already gone.
      }
    },
  };
}
