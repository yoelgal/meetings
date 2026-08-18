// better-dev's blast-radius guard, in omp's hook API.
//
// The policy lives in `.better-dev/` (safety-denylist, the scope boundary) and the checks live in
// `.better-dev/bin/bd-guard`. This file is only the wiring: omp's `tool_call` event is its
// pre-execution hook, so a destructive shell command or a write to a high-consequence path is
// stopped here rather than escalated after the fact.
//
// Why this exists at all: better-dev ships the same guard for Claude Code as a `PreToolUse` entry in
// `.claude/settings.json`, and its omp adapter records that omp "has no pre-execution hook". That is
// wrong - `tool_call` can return `{ block, reason }` and can ask through `ctx.ui.confirm` - and this
// repo runs on omp, so the gate would otherwise be recorded as wired while firing nowhere.
//
// Mapping onto bd-guard's input contract (it reads Claude Code's shape from stdin and answers with
// Claude Code's envelope, which is the format its own selftest pins):
//
//   bash            -> check-bash   {"tool_input":{"command": …}}
//   write           -> check-edit   {"tool_input":{"file_path": …}}
//   edit            -> check-edit   once per `[PATH#TAG]` section header in the hashline patch
//
// deny -> block. ask -> ctx.ui.confirm, and with no UI to ask, block: an unanswerable ask is not an
// allow. Anything else, including every other tool, returns undefined and stays silent.
//
// An ask nobody notices is the same as a hang, so `alert()` below fires before the dialog opens.
// Measured 2026-08-18: Herdr reports this pane as `agent_status: working` the whole time a confirm
// is on screen, because `herdr agent list` shows `screen_detection_skipped: true` for omp panes — it
// does not read the screen, it reads the terminal title, and omp keeps its spinner glyph there while
// a tool_call hook awaits. So the sidebar dot stays live, the operator has no reason to look, and the
// session sits blocked until somebody happens to glance at it. Nothing bd-guard can return changes
// that; the only fix available from inside the hook is to raise the alarm itself.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const TIMEOUT_MS = 5000;

// Raise the alarm before blocking on a dialog nothing else announces.
//
// Three channels because they fail in different places and none is reliable alone: the omp status
// line is the only one that survives in the TUI after the toast fades, `notify` is the in-app toast,
// and `herdr notification show` is the only one that reaches an operator whose Herdr tab is not the
// focused one — which is the case this exists for. `--sound request` because a silent notification
// on an unfocused tab is the problem restated.
//
// Every channel is best-effort and none may throw: this runs inside the tool_call handler, and omp
// blocks every tool call when that handler throws, so a failed notification must never become a
// wedged session.
function alert(ctx: HookContext, reason: string): void {
  try {
    ctx.ui?.setStatus?.("bd-guard", "waiting for approval");
  } catch {}
  try {
    ctx.ui?.notify?.(`better-dev guard needs approval: ${reason}`, "warn");
  } catch {}
  if (process.env.HERDR_ENV === "1") {
    try {
      spawnSync("herdr", ["notification", "show", "better-dev guard needs approval",
        "--body", reason, "--sound", "request"], { timeout: TIMEOUT_MS, stdio: "ignore" });
    } catch {}
  }
}

function alertCleared(ctx: HookContext): void {
  try {
    ctx.ui?.setStatus?.("bd-guard", "");
  } catch {}
}

interface ToolCallEvent {
  toolName?: string;
  input?: Record<string, unknown>;
}

interface HookContext {
  cwd?: string;
  hasUI?: boolean;
  // Only `confirm` is required. `notify` and `setStatus` are optional because this interface is a
  // hand-written shape for what omp passes, not an import of its type - a host that does not offer
  // them must degrade to a silent ask rather than a crashed hook.
  ui?: {
    confirm(title: string, message: string): Promise<boolean>;
    notify?(message: string, type?: string): void;
    setStatus?(key: string, text: string): void;
  };
}

interface BlockResult {
  block: true;
  reason: string;
}

interface HookApi {
  on(
    event: "tool_call",
    handler: (event: ToolCallEvent, ctx: HookContext) => Promise<BlockResult | undefined>,
  ): void;
}

type Decision = { decision: string; reason: string } | undefined;

// One bd-guard call. Returns undefined for "nothing to say" and for every failure mode: a missing
// script, a non-zero exit, unparseable output. Fail open is deliberate here - this hook sits in
// front of EVERY tool call, and omp blocks the call when a tool_call handler throws, so a guard that
// crashed would wedge the whole session instead of guarding it.
function ask(cwd: string, mode: "check-bash" | "check-edit", field: string, value: string): Decision {
  try {
    const guard = join(cwd, ".better-dev", "bin", "bd-guard");
    if (!existsSync(guard)) return undefined;
    const res = spawnSync("bash", [guard, mode], {
      cwd,
      input: JSON.stringify({ tool_input: { [field]: value } }),
      encoding: "utf8",
      timeout: TIMEOUT_MS,
      stdio: ["pipe", "pipe", "ignore"],
    });
    if (res.status !== 0 || typeof res.stdout !== "string") return undefined;

    // Narrowed rather than cast: this is bd-guard's stdout, so the shape is checked at the boundary
    // and a guard that ever answers something else reads as silence instead of a fabricated allow.
    const parsed: unknown = JSON.parse(res.stdout);
    if (!parsed || typeof parsed !== "object" || !("hookSpecificOutput" in parsed)) return undefined;
    const out: unknown = parsed.hookSpecificOutput;
    if (!out || typeof out !== "object" || !("permissionDecision" in out)) return undefined;
    if (typeof out.permissionDecision !== "string" || out.permissionDecision.length === 0) return undefined;

    const explained =
      "permissionDecisionReason" in out && typeof out.permissionDecisionReason === "string"
        ? out.permissionDecisionReason
        : "[better-dev] guard";
    return { decision: out.permissionDecision, reason: explained };
  } catch {
    return undefined;
  }
}

// The paths a hashline patch writes to: its `[PATH#TAG]` section headers, which are the only place
// the file path appears. A patch naming several files is checked once per file.
function editPaths(body: string): string[] {
  const found: string[] = [];
  for (const match of body.matchAll(/^\[([^\]\n]+)#[0-9A-Za-z]{4}\]/gm)) {
    const path = match[1];
    if (path && !found.includes(path)) found.push(path);
  }
  return found;
}

export default function (pi: HookApi): void {
  pi.on("tool_call", async (event, ctx) => {
    try {
      const cwd = ctx.cwd ?? process.cwd();
      const input = event.input ?? {};
      const checks: Decision[] = [];

      switch (event.toolName) {
        case "bash":
          checks.push(ask(cwd, "check-bash", "command", typeof input.command === "string" ? input.command : ""));
          break;
        case "write":
          checks.push(ask(cwd, "check-edit", "file_path", typeof input.path === "string" ? input.path : ""));
          break;
        case "edit":
          for (const path of editPaths(typeof input.input === "string" ? input.input : "")) {
            checks.push(ask(cwd, "check-edit", "file_path", path));
          }
          break;
        default:
          return undefined;
      }

      // A deny anywhere in the batch wins over an ask, and an ask over silence.
      const denied = checks.find((c) => c?.decision === "deny");
      if (denied) return { block: true, reason: denied.reason };

      const queried = checks.find((c) => c?.decision === "ask");
      if (!queried) return undefined;

      // The no-UI case alerts too. It is the worse one: a subagent has no dialog to show, so the
      // call is refused outright, and without this the operator sees only a worker that failed for
      // reasons buried in its transcript.
      if (!ctx.hasUI || !ctx.ui) {
        alert(ctx, `${queried.reason} (no UI to ask - blocked)`);
        return { block: true, reason: `${queried.reason} (no UI to ask - blocked)` };
      }
      alert(ctx, queried.reason);
      try {
        const approved = await ctx.ui.confirm("better-dev guard", queried.reason);
        return approved ? undefined : { block: true, reason: "[better-dev] declined by the operator" };
      } finally {
        // In a `finally` so the status line clears on a declined dialog and on an aborted session
        // too, not only on approval. A "waiting for approval" that outlives the wait is worse than
        // no status at all: it trains the operator to ignore the one line that means they are needed.
        alertCleared(ctx);
      }
    } catch {
      return undefined; // never throw: a throwing tool_call handler blocks every tool omp runs
    }
  });
}
