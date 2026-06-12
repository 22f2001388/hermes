---
name: coding-agent
description: "Delegate heavy or multi-file coding work to a dedicated coding CLI — claude-code (`claude`) or opencode (`opencode`) — running headless in the workspace, instead of writing it all inline. Use for refactors, multi-file features, codebase exploration, build/test loops, or any task better handled by a full agentic coding loop. Both run with full autonomy inside the workspace and authenticate from the provider keys already in the environment."
version: 1.0.0
author: Hermes Assistant
license: MIT
platforms: [linux, macos, windows]
environments: [cron, cli, gateway]
metadata:
  hermes:
    tags: [Coding, Delegation, Tools, Autonomy, Refactor, Workspace]
    related_skills: [autonomy-loop, self-improve]
---

# coding-agent — hand a coding subtask to a real coding CLI

Two full coding agents ship on PATH in this container: **claude-code** (`claude`)
and **opencode** (`opencode`). When a task is more than a quick edit — a refactor
across files, a new feature, a bug hunt through unfamiliar code, a red-green test
loop — don't grind it out inline. Delegate it to one of these CLIs: they run their
own agentic loop (read, edit, run, iterate) and hand back the result.

Both are pre-configured for **unattended, full-autonomy** use: they can read,
edit, and run commands in the workspace without prompting. Auth is already wired —
they read the same provider keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) that
the gateway uses. You do not log in or pass keys.

## Prerequisite

You need a shell / exec tool to launch these (they are external processes). If you
have no way to run a shell command, this skill does not apply — do the work inline.

## When to use this

- Multi-file refactor or feature — let the CLI hold the whole change in its loop.
- Exploring an unfamiliar codebase before answering — cheaper than reading inline.
- A build/lint/test red-green loop — the CLI iterates until green.
- Anything where a dedicated coding context beats doing it in the chat thread.

Do **not** use it for a one-line edit or a question you can answer directly.

## How to run

Always work inside the agent workspace. Pass the task as one clear prompt.

**claude-code** (Anthropic; strong at careful multi-file edits + reasoning):

```bash
cd "$HERMES_WEBUI_DEFAULT_WORKSPACE" 2>/dev/null || cd ~
claude -p "Refactor src/auth to use the new token helper; keep tests green." \
  --output-format text
```

- `-p` = non-interactive print mode (required for headless).
- Permission prompts are already bypassed via seeded settings; add
  `--permission-mode bypassPermissions` only if you override settings.
- `--output-format json` instead of `text` gives a structured result (session id,
  cost) you can parse.
- Pick a model with `--model <id>` if you need a specific one; otherwise the
  account default is used.

**opencode** (multi-provider; good when you want a non-Anthropic model):

```bash
cd "$HERMES_WEBUI_DEFAULT_WORKSPACE" 2>/dev/null || cd ~
opencode run "Add a /healthz route to the server and a test for it."
```

- `opencode run "<prompt>"` = one-shot headless.
- Default model is `opencode/mimo-v2.5-free` (set in the seeded config). Override
  per-call with `-m provider/model`, or globally via the
  `CODING_AGENT_OPENCODE_MODEL` env var. Run `opencode models` to list valid ids.
- `--format json` for machine-readable output; `--dir <path>` to set the working
  directory instead of `cd`.

## Choosing which

- **claude-code** — default for careful, correctness-critical edits and when the
  primary key is Anthropic.
- **opencode** — when you want a specific non-Anthropic model, or to compare a
  second opinion on the same task.

## Guardrails

- These agents have **full write + shell autonomy in the workspace** — scope the
  prompt tightly and point them at the workspace, not at system paths.
- They spend the **same provider API budget** as the gateway. One delegation =
  one full coding session worth of tokens. Use deliberately, not reflexively.
- Capture and report their final output; on failure, surface the last lines of
  their output rather than retrying blindly.
- Treat any file change they make as you would your own — review before
  presenting it as done.
