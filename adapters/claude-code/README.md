# The Claude Code adapter

Translates Claude Code's hook lifecycle into the pet's generic event vocabulary.
Nothing in `app/` knows Claude Code exists — this directory is the only thing that
does, which is what makes an adapter for another tool a matter of writing a new
`hooks.json` rather than touching the app.

## Install

Follow the step-by-step [install guide in the main README](../../README.md#install).
In short: build, start the pet, then install the plugin from the folder you
built, with the path typed bare (no quotes), and restart Claude Code:

```sh
./scripts/build.sh          # compiles the hook into plugin/bin/hookling-hook
./scripts/run.sh            # start the pet
```

```
/plugin marketplace add /Users/you/hookling
/plugin install hookling@hookling
```

The marketplace manifest is at the repo root (`.claude-plugin/marketplace.json`);
the plugin itself is `adapters/claude-code/plugin/`.

Build first. `plugin/bin/hookling-hook` is a compiled artifact and is deliberately
not committed, so a fresh clone has no hook until `scripts/build.sh` has run. A
missing hook is silent rather than noisy — Claude Code reports the failed command
and carries on.

## Event mapping

| Claude Code hook   | Generic event      | What the pet does                     |
| ------------------ | ------------------ | ------------------------------------- |
| `SessionStart`     | `session_started`  | Registers the session and waves        |
| `UserPromptSubmit` | `prompt_submitted` | Starts working                         |
| `PreToolUse`       | `work_started`     | Runs; also the heartbeat that keeps it running |
| `PostToolUse`      | `work_progress`    | Heartbeat                              |
| `SubagentStop`     | `work_progress`    | Heartbeat — the turn is still going    |
| `Notification`     | `attention_needed` | Looks up: a permission prompt or an idle nudge |
| `Stop`             | `work_finished`    | Turn done                              |
| `SessionEnd`       | `session_ended`    | Waves goodbye and forgets the session  |

Two events in the vocabulary are **not reachable from Claude Code**:
`work_failed` and `turn_failed`. Distinguishing a failed tool call from a
successful one means reading the tool result, and the hook deliberately never
looks at payload content (see below). They stay in the vocabulary for adapters
whose tools report failure structurally, and for `hooklingctl emit`.

Because every hook is a separate process, ordering between them is not
guaranteed under load. The state machine is written so that does not matter: the
states are prioritised rather than sequential, and heartbeats expire on a timer.

## What is sent

One line of JSON per hook, over a Unix domain socket:

```json
{"event":"work_started","session":"369ee3f3c2e67286"}
```

The event name is a literal from `hooks.json` — never derived from the payload.
The session field is an FNV-1a hash of `session_id`, so the pet can tell two
windows apart without holding anything that maps back to a transcript.

Prompts, tool arguments, file contents and tool output are never read into
memory in full, never written anywhere, and never sent. See the header comment in
`hooks/hookling-hook.c` for how the payload is scanned.

## Checking it works

```sh
HOOKLING_HOOK_DEBUG=1 ./build/bin/hookling-hook work_started </dev/null
./build/bin/hooklingctl status      # sessions should be listed
./build/bin/hooklingctl snapshot    # writes a PNG of the frame on screen
```

The hook always exits 0, including when the pet is not running. A desktop pet is
never a reason for a tool call to fail.
