import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const MODULE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const CONNECT_TIMEOUT_MS = 45_000;
const DAEMON_WAIT_MS = 8_000;
const PROBE_TIMEOUT_MS = 300;

let daemon: ChildProcess | null = null;

export type NativeMethod =
  | "status"
  | "create"
  | "move_app"
  | "restore"
  | "verify"
  | "capture"
  | "destroy";

export type NativePaths = {
  root: string;
  binary: string;
  socketPath: string;
};

export function nativePaths(): NativePaths {
  const root = process.env.AGENT_SCREEN_ROOT ?? MODULE_ROOT;
  return {
    root,
    binary: process.env.AGENT_SCREEN_BINARY ?? path.join(root, "dist", "AgentScreenLite"),
    socketPath:
      process.env.AGENT_SCREEN_SOCKET ??
      path.join(os.homedir(), "Library", "Application Support", "agent-screen-lite", "control.sock"),
  };
}

export function resetDaemonForTests(): void {
  daemon = null;
}

export function stopDaemonForTests(): void {
  if (daemon?.pid) {
    try {
      process.kill(-daemon.pid, "SIGTERM");
    } catch {
      try {
        process.kill(daemon.pid, "SIGTERM");
      } catch {
        // Already gone.
      }
    }
  }
  daemon = null;
}

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorText(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return String(error);
}

function jsonLine(obj: Record<string, unknown>): Buffer {
  return Buffer.from(`${JSON.stringify(obj)}\n`, "utf8");
}

function readLine(socket: net.Socket, timeoutMs: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("timeout"));
    }, timeoutMs);
    const onData = (chunk: Buffer) => {
      chunks.push(chunk);
      total += chunk.length;
      const data = Buffer.concat(chunks, total);
      if (data.includes(0x0a)) {
        cleanup();
        resolve(data);
      }
    };
    const onEnd = () => {
      cleanup();
      reject(new Error("AgentScreenLite closed the control socket"));
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("end", onEnd);
      socket.off("error", onError);
    };
    socket.on("data", onData);
    socket.on("end", onEnd);
    socket.on("error", onError);
  });
}

function connectUnix(socketPath: string, timeoutMs: number): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("timeout"));
    }, timeoutMs);
    socket.once("connect", () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function sendRequest(
  method: string,
  params: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const { socketPath } = nativePaths();
  const socket = await connectUnix(socketPath, CONNECT_TIMEOUT_MS);
  try {
    socket.write(jsonLine({ method, params }));
    const data = await readLine(socket, CONNECT_TIMEOUT_MS);
    const newline = data.indexOf(0x0a);
    const line = data.subarray(0, newline).toString("utf8");
    const result: unknown = JSON.parse(line);
    if (!isJsonObject(result)) {
      throw new Error("AgentScreenLite returned a non-object");
    }
    return result;
  } finally {
    socket.destroy();
  }
}

function daemonRunning(): boolean {
  return daemon !== null && daemon.exitCode === null && daemon.signalCode === null;
}

async function probeSocket(socketPath: string): Promise<boolean> {
  try {
    const socket = await connectUnix(socketPath, PROBE_TIMEOUT_MS);
    socket.destroy();
    return true;
  } catch {
    return false;
  }
}

export async function startDaemon(): Promise<void> {
  if (daemonRunning()) return;
  const { binary, socketPath } = nativePaths();
  if (!fs.existsSync(binary)) {
    throw new Error(`native helper is missing: ${binary}`);
  }
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  const logPath = path.join(os.homedir(), "Library", "Logs", "agent-screen-lite.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logFd = fs.openSync(logPath, "a");
  try {
    daemon = spawn(binary, ["--daemon"], {
      detached: true,
      stdio: ["ignore", logFd, logFd],
      env: { ...process.env, AGENT_SCREEN_SOCKET: socketPath },
    });
  } finally {
    fs.closeSync(logFd);
  }
  daemon.unref();

  const deadline = Date.now() + DAEMON_WAIT_MS;
  while (Date.now() < deadline) {
    if (fs.existsSync(socketPath) && (await probeSocket(socketPath))) return;
    if (!daemonRunning()) break;
    await delay(100);
  }

  let detail = "";
  try {
    detail = fs.readFileSync(logPath, "utf8").slice(-1000);
  } catch {
    // The helper may have died before creating a log.
  }
  throw new Error(`AgentScreenLite failed to start; see ${logPath}\n${detail}`);
}

function isTransportError(error: unknown): boolean {
  if (error instanceof SyntaxError) return false;
  if (!(error instanceof Error)) return false;
  return true;
}

export async function rawCall(
  method: NativeMethod,
  params: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await sendRequest(method, params);
    } catch (error) {
      if (!isTransportError(error)) throw error;
      if (attempt === 1) {
        throw new Error(`AgentScreenLite unavailable: ${errorText(error)}`);
      }
      await startDaemon();
    }
  }
  throw new Error("unreachable");
}

export async function callNative(
  method: NativeMethod,
  params: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const response = await rawCall(method, params);
  if (!response.ok) {
    const error = response.error;
    const message =
      isJsonObject(error) && typeof error.message === "string"
        ? error.message
        : "native helper error";
    throw new Error(message);
  }
  const result = response.result;
  return isJsonObject(result) ? result : {};
}
