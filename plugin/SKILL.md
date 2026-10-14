---
name: agent-screen-lite
description: "Use the local AgentScreenLite MCP to give a GUI agent a named macOS virtual work screen. Trigger when an agent needs to isolate its app windows from the user's physical desktop, move a running app into a task screen, capture a target display, restore windows, or diagnose virtual-display readiness."
---

# Agent Screen Lite

Use the `agent-screen-lite` MCP as a reversible work-screen lifecycle. It owns one or more native macOS virtual displays and tracks window placement checkpoints in the current login session.

## Scope and limits

- A virtual screen is a display surface, not a second macOS user session.
- Focus, keyboard and pointer are still shared with the login session. Never promise independent input or simultaneous human/agent control.
- The helper uses macOS's private `CGVirtualDisplay` classes. Treat OS-version compatibility as a live capability check, not a guarantee.
- The MCP can create, move, capture, restore and destroy. The MCP does not replace a computer-use capture/input tool; use the authorized native computer-use surface for actual visual interaction.
- Keep physical displays enabled and a physical display as main during ordinary setup.

## Prepare a task screen

1. Call `screen_status` first. Confirm `api_available`, current virtual screens, `accessibility_trusted`, and the physical/virtual display inventory.
2. Reuse a task-owned screen with the exact name when it exists. Do not rename or destroy an unknown screen.
3. Otherwise call `screen_create` with a short name such as `Codex · Blender`, `width: 1920`, `height: 1080`, and `hi_dpi: false` unless the task needs another resolution.
4. Call `screen_verify` before moving an app. It must report the target display online and produce a fresh PNG capture. A capture proves visibility of the display surface only.
5. Move only the requested running app. Prefer `bundle_id` and pass `screen`; omit `source_display_id` to select physical-display windows only. Pass an explicit source display ID only after inspecting it with `screen_status`. The operation must be narrow enough that other task windows are not swept into the move.
6. Call `screen_verify` again after the move. Discard coordinates and screenshots from before the move; display topology changes can invalidate them.
7. Use the existing authorized computer-use tool for one reversible target-app action. Confirm the change in a new screenshot. Stop if the capture is blank/stale, input lands in the wrong window, a security prompt appears, or Accessibility positioning is rejected.

## Finish and recover

1. Save the user's work through the target app's normal workflow.
2. Call `screen_restore` with `screen` and, when only one app should return, `bundle_id`. The helper refuses to claim success when a tracked window cannot be verified.
3. Call `screen_status` and confirm the app is back on a physical display before destroying the screen.
4. Call `screen_destroy`. It restores remaining tracked windows first and refuses to remove a screen if recovery is not confirmed.
5. If recovery fails, leave the screen running and report the exact screen, app and blocker. Do not use a force flag or quit the helper to make the display disappear.

## Verification language

Report claims separately:

- `PASS`: the requested display exists or the requested window move/restore was observed by the native helper, and `screen_verify` produced a fresh capture.
- `BLOCKED`: the native helper or OS permission/session could not be reached.
- `FAIL`: the real target operation was reached and returned an incorrect result.
- A successful `screen_verify` is not evidence of keyboard/mouse isolation, locked-session operation, monitor power-off, or unattended long-running reliability.

Keep capture paths local. Do not publish screenshots or display identifiers unless the user asks for them.
