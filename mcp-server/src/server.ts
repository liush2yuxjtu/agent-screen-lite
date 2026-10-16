import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { callNative, type NativeMethod } from "./native.js";

export const VERSION = "0.1.0";
export const SERVER_NAME = "agent-screen-lite";
export const INSTRUCTIONS =
  "Use screen_create, screen_move_app, screen_verify, screen_restore, and screen_destroy as a reversible work-screen lifecycle. A virtual display shares the login session's focus, keyboard, and pointer; it is not input isolation.";

export const TOOL_NAMES = [
  "screen_status",
  "screen_create",
  "screen_move_app",
  "screen_restore",
  "screen_verify",
  "screen_capture",
  "screen_destroy",
] as const;

const TOOL_TO_NATIVE = {
  screen_status: "status",
  screen_create: "create",
  screen_move_app: "move_app",
  screen_restore: "restore",
  screen_verify: "verify",
  screen_capture: "capture",
  screen_destroy: "destroy",
} as const satisfies Record<(typeof TOOL_NAMES)[number], NativeMethod>;

const emptyObject = z.object({}).strict();

const screenCreateInput = z
  .object({
    name: z.string().min(1).max(80),
    width: z.number().int().min(320).max(8192).optional(),
    height: z.number().int().min(240).max(8192).optional(),
    hi_dpi: z.boolean().optional(),
  })
  .strict();

const screenMoveAppInput = z
  .object({
    screen: z.string().optional(),
    display_id: z.number().int().min(1).optional(),
    bundle_id: z.string().optional(),
    app_path: z.string().optional(),
    source_display_id: z.number().int().min(0).optional(),
  })
  .strict()
  .refine((value) => Boolean(value.bundle_id) || Boolean(value.app_path), {
    message: "provide bundle_id or app_path",
  });

const screenRestoreInput = z
  .object({
    screen: z.string(),
    display_id: z.number().int().min(1).optional(),
    bundle_id: z.string().optional(),
  })
  .strict();

const screenNamedInput = z
  .object({
    screen: z.string(),
    display_id: z.number().int().min(1).optional(),
  })
  .strict();

const screenCaptureInput = z
  .object({
    screen: z.string(),
    display_id: z.number().int().min(1).optional(),
    path: z.string().optional(),
  })
  .strict();

function compactParams(value: object): Record<string, unknown> {
  const params: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (entry !== undefined) params[key] = entry;
  }
  return params;
}

function toolSuccess(result: Record<string, unknown>) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(result, null, 2) }],
    structuredContent: result,
  };
}

function toolFailure(error: unknown) {
  return {
    isError: true as const,
    content: [
      {
        type: "text" as const,
        text: error instanceof Error ? error.message : String(error),
      },
    ],
  };
}

async function forward(name: (typeof TOOL_NAMES)[number], args: object) {
  try {
    const result = await callNative(TOOL_TO_NATIVE[name], compactParams(args));
    return toolSuccess(result);
  } catch (error) {
    return toolFailure(error);
  }
}

export function createServer(): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: VERSION },
    {
      instructions: INSTRUCTIONS,
      capabilities: { tools: { listChanged: false } },
    },
  );

  server.registerTool(
    "screen_status",
    {
      title: "Screen status",
      description:
        "Read virtual displays, online displays, Accessibility readiness, and whether a second display is available for safe window isolation.",
      inputSchema: emptyObject,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_status", args),
  );

  server.registerTool(
    "screen_create",
    {
      title: "Create virtual screen",
      description: "Create or reuse a named macOS virtual work screen. This does not move apps.",
      inputSchema: screenCreateInput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_create", args),
  );

  server.registerTool(
    "screen_move_app",
    {
      title: "Move app to virtual screen",
      description:
        "Move an already running app's ordinary windows from one source display into a named virtual screen. Defaults to physical displays only when source_display_id is omitted.",
      inputSchema: screenMoveAppInput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_move_app", args),
  );

  server.registerTool(
    "screen_restore",
    {
      title: "Restore app windows",
      description:
        "Restore one app or all tracked app windows from a virtual screen to their recorded physical placement.",
      inputSchema: screenRestoreInput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_restore", args),
  );

  server.registerTool(
    "screen_verify",
    {
      title: "Verify virtual screen",
      description:
        "Verify that a virtual screen is online and capturable; reports permissions and writes a local PNG evidence file. It does not claim keyboard or mouse isolation.",
      inputSchema: screenNamedInput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_verify", args),
  );

  server.registerTool(
    "screen_capture",
    {
      title: "Capture virtual screen",
      description: "Capture one virtual display to a local PNG for visual inspection.",
      inputSchema: screenCaptureInput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_capture", args),
  );

  server.registerTool(
    "screen_destroy",
    {
      title: "Destroy virtual screen",
      description:
        "Restore tracked windows and remove a virtual screen. Refuses to destroy when restoration cannot be verified.",
      inputSchema: screenNamedInput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    async (args) => forward("screen_destroy", args),
  );

  return server;
}
