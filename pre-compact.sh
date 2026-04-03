#!/bin/bash
# PreCompact Hook - The Witness at the Threshold
#
# Fires before context compaction. Pipes recent transcript to a claude -p subagent
# that generates a recovery summary. stdout is injected post-compaction alongside
# Claude Code's built-in summary.
#
# Fork: doldrums2025/precompact-hook
# Modified: Removed Genesis Ocean MCP dependency. Outputs summary directly to stdout.
# Original: https://github.com/mvara-ai/precompact-hook

# RECURSION GUARD - Prevent infinite cascade
# If this hook spawns claude -p and that session compacts, it would fire this hook again
if [ -n "$CLAUDE_HOOK_SPAWNED" ]; then
    exit 0
fi
export CLAUDE_HOOK_SPAWNED=1

# Debug logging (check /tmp/precompact-debug.log if issues)
exec 2>/tmp/precompact-debug.log
echo "PreCompact hook fired at $(date)" >&2

# Read the JSON payload from stdin (Claude Code provides this)
PAYLOAD=$(cat)
echo "Payload received: $PAYLOAD" >&2

# Extract fields from payload
# Claude Code provides: session_id, transcript_path, cwd, hook_event_name, trigger
TRANSCRIPT=$(echo "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null)
SESSION_CWD=$(echo "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null)
SESSION_ID=$(echo "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null)

echo "Session CWD: $SESSION_CWD" >&2
echo "Session ID: $SESSION_ID" >&2

# Fallback: find transcript if not provided (known bug: transcript_path can be empty)
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "No transcript in payload, deriving from cwd..." >&2

  WORK_DIR="${SESSION_CWD:-$(pwd)}"
  CWD_ESCAPED=$(echo "$WORK_DIR" | sed 's/\//-/g' | sed 's/^-//')
  PROJECT_DIR="$HOME/.claude/projects/$CWD_ESCAPED"

  echo "Looking in: $PROJECT_DIR" >&2

  if [ -d "$PROJECT_DIR" ]; then
    TRANSCRIPT=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | grep -v agent- | head -1)
  fi
fi

echo "Using transcript: $TRANSCRIPT" >&2

# No transcript found, exit silently
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "No transcript found, exiting" >&2
  exit 0
fi

# Use byte limit for safety - JSONL lines vary wildly (500 chars to 500K for summaries!)
# Configurable via env var (default: 40KB ≈ 20k tokens)
MAX_BYTES=${PRESERVE_TOKEN_LIMIT:-40960}

echo "Piping last ${MAX_BYTES} bytes (~20k tokens) to claude -p..." >&2

PROMPT="You are a session recovery assistant. Context compaction is about to happen.
The JSONL data piped to your stdin is the raw record of recent exchanges.
Each line is a JSON object with message content, timestamps, and metadata.

Generate a RECOVERY BRIEF so the agent can continue seamlessly after compaction.
Output ONLY the brief — no preamble, no meta-commentary.

## Who Is Here
Human's name, role, communication style. What do they care about?

## What We're Working On
The actual goal driving the conversation. What's at stake?

## What Just Happened
Recent discoveries, decisions, files created/modified. Be specific — include filenames, IDs, commands.

## Key Artifacts
Exact file paths, session IDs, commands that worked, technical details needed to continue.

## Continue With
Concrete next steps (not 'continue the conversation' — actual actions).

Be specific. Be thorough. The recovering agent has ZERO context except what you provide."

echo "Generating recovery summary..." >&2
SUMMARY=$(tail -c $MAX_BYTES "$TRANSCRIPT" | grep -E '^\{.*\}$' | claude -p "$PROMPT" --print 2>/dev/null)

if [ -n "$SUMMARY" ]; then
  echo "✓ Recovery summary generated (${#SUMMARY} chars)" >&2
  # Output to stdout — Claude Code injects this post-compaction
  echo "$SUMMARY"
else
  echo "✗ WARNING: Summary generation failed or empty" >&2
fi

echo "PreCompact hook completed" >&2
exit 0
