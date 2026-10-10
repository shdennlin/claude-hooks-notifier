#!/usr/bin/env bash
# Test script for Claude Code notification handler
# Simulates different hook events to verify Telegram notifications

set -euo pipefail

HANDLER="./scripts/claude-notification-handler.sh"

if [[ ! -x "$HANDLER" ]]; then
    echo "❌ Error: Handler script not found or not executable: $HANDLER"
    exit 1
fi

echo "🧪 Testing Claude Code Notification Handler"
echo "=========================================="
echo ""

# Create session start timestamp for duration tests
mkdir -p ~/.claude
echo "📝 Setting up test environment"

# Fixture transcript: the latest custom-title (/rename) should win over ai-title
FIXTURE_TRANSCRIPT="$(mktemp -t claude-notify-test)"
trap 'rm -f "$FIXTURE_TRANSCRIPT"' EXIT
cat > "$FIXTURE_TRANSCRIPT" <<'JSONL'
{"type":"ai-title","aiTitle":"Auto title","sessionId":"test-123"}
{"type":"custom-title","customTitle":"old-name","sessionId":"test-123"}
{"type":"custom-title","customTitle":"修正 <auth> & 通知","sessionId":"test-123"}
JSONL
echo ""

# Test 0: Session Start (silent: records the start time for the duration tests)
echo "📝 Test 0: Session Start (no notification)"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "SessionStart",
  "source": "startup"
}' | $HANDLER
sleep 1
echo ""

# Test 0b: Auto session name from git branch (stdout must be only the hook JSON)
echo "📝 Test 0b: Auto session title"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
HOOK_STDOUT="$(echo '{
  "session_id": "test-789",
  "cwd": "'"$PWD"'",
  "hook_event_name": "SessionStart",
  "source": "startup"
}' | CLAUDE_NOTIFY_TELEGRAM=false CLAUDE_NOTIFY_DESKTOP=false $HANDLER 2>/dev/null)"
case "$BRANCH" in
    ""|HEAD|main|master) EXPECTED="" ;;
    *) EXPECTED="$BRANCH" ;;
esac
ACTUAL="$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.sessionTitle // empty' 2>/dev/null || echo "")"
if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo "✅ sessionTitle output: '${ACTUAL}' (branch: ${BRANCH:-none})"
else
    echo "❌ sessionTitle output: expected '${EXPECTED}', got stdout: ${HOOK_STDOUT}"
    exit 1
fi
rm -f ~/.claude/session_start.test-789.tmp
echo ""

# Test 1: Tool Approval Notification
echo "📝 Test 1: Tool Approval Request"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "Notification",
  "message": "Claude needs your permission to use Bash"
}' | $HANDLER
echo ""

# Test 2: Generic Notification
echo "📝 Test 2: Generic Notification"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "Notification",
  "message": "Some other notification message"
}' | $HANDLER
echo ""

# Test 2b: Background agent needs input
echo "📝 Test 2b: Agent Needs Input"
echo '{
  "session_id": "test-123",
  "cwd": "/Users/test/project",
  "hook_event_name": "Notification",
  "notification_type": "agent_needs_input",
  "message": "Agent research-1 is waiting for your answer"
}' | $HANDLER
echo ""

# Test 2c: MCP elicitation (the wording must not read as a permission request)
echo "📝 Test 2c: Input Requested"
echo '{
  "session_id": "test-123",
  "cwd": "/Users/test/project",
  "hook_event_name": "Notification",
  "notification_type": "elicitation_dialog",
  "message": "Allow the server to continue? Fill in the form"
}' | $HANDLER
echo ""

# Test 2d: a turn that ended on an API error fires StopFailure, not Stop
echo "📝 Test 2d: Turn Failed"
echo '{
  "session_id": "test-123",
  "cwd": "/Users/test/project",
  "hook_event_name": "StopFailure",
  "error": "authentication_failed",
  "last_assistant_message": "Failed to authenticate. API Error: 401 API key is invalid."
}' | $HANDLER
echo ""

# Test 3: Task Completion (Stop event)
echo "📝 Test 3: Task Completion"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "Stop",
  "last_assistant_message": "\n## Fixed `<auth>` & retry\n\nDetails follow..."
}' | $HANDLER
echo ""

# Test 4b: Session name from SessionStart's session_title input (no notification)
echo "📝 Test 4b: Session Start with session_title (no notification)"
echo '{
  "session_id": "test-456",
  "cwd": "/Users/test/project",
  "hook_event_name": "SessionStart",
  "session_title": "named-at-launch"
}' | $HANDLER
rm -f ~/.claude/session_start.test-456.tmp
echo ""

# Test 5: Session End
echo "📝 Test 5: Session End"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "SessionEnd"
}' | $HANDLER
echo ""

echo "=========================================="
echo "✅ All tests completed!"
echo ""
echo "If TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are set,"
echo "you should have received 7 different Telegram notifications:"
echo "  1. Tool Approval Request"
echo "  2. Generic Notification"
echo "  2b. Agent Needs Input"
echo "  2c. Input Requested (MCP elicitation)"
echo "  2d. Task Failed (StopFailure)"
echo "  3. Task Completion (with preview + duration)"
echo "  5. Session End (with duration)"
echo ""
echo "Tests 0, 0b and 4b are SessionStart events and send nothing."
echo ""
echo "If not set, you should see warning messages instead."
