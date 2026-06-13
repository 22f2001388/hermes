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
- Tighten scope with `--allowedTools Read,Edit,Bash` (or a narrower subset) when
  the task doesn't need full autonomy — fewer tools = smaller blast radius.

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

## Choosing which — by task shape

- **Multi-file refactor / correctness-critical edit** → claude-code. Strongest at
  holding a careful change across files and reasoning about edge cases.
- **New feature / red-green test loop** → either; claude-code when the logic is
  subtle, opencode (cheaper model) when it's mechanical.
- **Codebase exploration / "how does X work"** → opencode on a long-context model
  (`-m` a large-context id) or claude-code — reading is cheap, pick on budget.
- **Second opinion on the same task** → run opencode with a non-Anthropic model
  and diff the two results.
- **Tight budget** → opencode on a free/cheap model (default `mimo-v2.5-free`);
  claude-code spends Anthropic budget on every call.

## Guardrails

- These agents have **full write + shell autonomy in the workspace** — scope the
  prompt tightly and point them at the workspace, not at system paths.
- They spend the **same provider API budget** as the gateway. One delegation =
  one full coding session worth of tokens. Use deliberately, not reflexively.
- Capture and report their final output; on failure, surface the last lines of
  their output rather than retrying blindly.
- Treat any file change they make as you would your own — review before
  presenting it as done.
- **Delegate on a clean tree.** Commit or stash first, then let the agent work, so
  you can `git diff` exactly what it changed and `git checkout .` to roll back a
  bad run. (On ephemeral HF FS the diff-review still matters even without history.)
- **Never let a delegated agent run these** — scope the prompt and `--allowedTools`
  so it can't: `rm -rf` outside the workspace, `git push` / `git push --force`,
  `curl … | sh` or `… | bash` (remote-code exec), credential or `.env`
  exfiltration, or package publishes. If a task seems to need one, stop and do it
  yourself.
