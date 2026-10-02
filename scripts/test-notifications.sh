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

# Test 0: Session Start
echo "📝 Test 0: Session Start"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "SessionStart"
}' | $HANDLER
sleep 1
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

# Test 3: Task Completion (Stop event)
echo "📝 Test 3: Task Completion"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "Stop"
}' | $HANDLER
echo ""

# Test 4: Subagent Completion
echo "📝 Test 4: Subagent Completion"
echo '{
  "session_id": "test-123",
  "transcript_path": "'"$FIXTURE_TRANSCRIPT"'",
  "cwd": "/Users/test/project",
  "hook_event_name": "SubagentStop"
}' | $HANDLER
echo ""

# Test 4b: Session name from SessionStart's session_title input
echo "📝 Test 4b: Session Start with session_title"
echo '{
  "session_id": "test-456",
  "cwd": "/Users/test/project",
  "hook_event_name": "SessionStart",
  "session_title": "named-at-launch"
}' | $HANDLER
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
echo "  0. Session Start"
echo "  1. Tool Approval Request"
echo "  2. Generic Notification"
echo "  3. Task Completion"
echo "  4. Subagent Completion"
echo "  5. Session End"
echo ""
echo "If not set, you should see warning messages instead."
