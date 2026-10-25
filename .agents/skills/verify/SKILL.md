---
name: verify
description: Verify agent-screen-lite — native screen lifecycle (when on macOS with the helper) plus TLC on formal/ when present. Overall PASS only when every required check is PASS; TLC is required whenever formal/ exists.
---

# /verify — agent-screen-lite

Use when asked to `/verify`, after changing `mcp-server/`, `native/`, `formal/`, or before trusting the MCP in automation.

Repos gate is this skill (not GitHub Actions). Every feature PR must extend this skill with how that feature is checked.

## Verdict model

| Verdict | Meaning |
| --- | --- |
| **PASS** | The claim was exercised and required observables matched (or TLC found no error). |
| **FAIL** | Reached a counterexample (wrong lifecycle result, or TLC invariant violation / missing TLC tooling while `formal/` exists). |
| **BLOCKED** | Environment could not run the check (not on macOS, helper/API unavailable, Accessibility denied). |
| **SKIP** | Out of scope for this run (caller asked only for formal, or only for runtime). |

**No partial pass.** Overall **PASS** only if every non-SKIP check is PASS. Any required **FAIL** → overall FAIL. Else any required **BLOCKED** → overall BLOCKED.

When `formal/` exists, **tla_formal** is required (not SKIP). Missing Java/`tla2tools.jar` → **FAIL** with install instructions below.

## Checks

### 1. Package / build (cheap)

From repo root:

```bash
./build.sh
# or: (cd mcp-server && npm test && npm run build) when package scripts exist
```

**PASS** = build exits 0. Does **not** prove a live virtual display.

### 2. Runtime screen lifecycle (macOS + helper)

Follow `skill/agent-screen-lite/SKILL.md` / `plugin/SKILL.md`:

1. `screen_status` — `api_available`, inventory, Accessibility.
2. `screen_create` (short name) → `screen_verify` (fresh PNG).
3. Optional narrow `screen_move_app` → `screen_verify` again.
4. `screen_restore` → `screen_status` confirms app on a physical display.
5. `screen_destroy` (refuses if recovery not confirmed).

| Outcome | Verdict |
| --- | --- |
| Observed create/verify/(move)/restore/destroy as claimed | **PASS** |
| Helper reached and returned an incorrect result | **FAIL** |
| Not macOS, helper missing, API unavailable, permission/session blocked | **BLOCKED** |

A successful `screen_verify` is **not** evidence of keyboard/mouse isolation, locked-session operation, or unattended reliability.

### 3. Formal (TLA+) — `tla_formal` (required when `formal/` exists)

Models named virtual-display lifecycle safety (`Inv_LiveBounded`, live-only move/capture, no double-destroy). See `formal/README.md`.

#### Install TLC

1. Java 11+ (`java -version`).
2. Download `tla2tools.jar` from [TLA+ releases](https://github.com/tlaplus/tlaplus/releases).

Optional: `export TLA2TOOLS_JAR=/path/to/tla2tools.jar`.

#### Run

```bash
JAR="${TLA2TOOLS_JAR:-tla2tools.jar}"
test -f "$JAR" || JAR="./tla2tools.jar"
command -v java >/dev/null || { echo "tla_formal FAIL: java missing — install JDK 11+"; exit 1; }
test -f "$JAR" || { echo "tla_formal FAIL: tla2tools.jar missing — https://github.com/tlaplus/tlaplus/releases"; exit 1; }
( cd formal && java -cp "$JAR" tlc2.TLC -config Spec.cfg Spec.tla )
```

| Outcome | Verdict |
| --- | --- |
| TLC exits 0 + `No error has been found` | **PASS** |
| Invariant/property violation or TLC error | **FAIL** |
| `java` or `tla2tools.jar` missing while `formal/` exists | **FAIL** (install above; do not SKIP) |

Read TLC results with the pstack `/statechart` skill (commands change by release — do not copy them here).

## Report shape

```text
## /verify
overall: PASS | FAIL | BLOCKED | SKIP

- package:    PASS|FAIL|SKIP
- runtime:    PASS|FAIL|BLOCKED|SKIP  — screen_* lifecycle on macOS helper
- tla_formal: PASS|FAIL|SKIP          — TLC on formal/Spec.tla (required when formal/ exists)

evidence:
- screen_verify PNG path(s) (local only; do not publish unless asked)
- formal TLC stdout (No error has been found)

notes: <OS, api_available, Accessibility, TLA2TOOLS_JAR>
```

## Loop

1. If `formal/` exists, run `tla_formal` — FAIL on missing jar/Java or any TLC error.
2. Run package/build.
3. On a Mac with the helper, run runtime lifecycle; elsewhere mark runtime **BLOCKED** (not FAIL).
4. Fix FAIL in code or Spec (do not weaken invariants to get green).
5. Re-run until overall PASS or only remaining BLOCKED is environment.
