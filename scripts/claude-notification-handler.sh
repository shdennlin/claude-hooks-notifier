#!/usr/bin/env bash
# Claude Code Notification Handler for Telegram
# Sends different notifications based on hook event type and context

# shellcheck disable=SC2059 # printf format is intentionally from variable
set -euo pipefail

# URL encode function for safe Telegram messages
url_encode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Parse JSON with jq if available, fallback to grep/sed
parse_json() {
    local input="$1"
    local field="$2"

    if command -v jq >/dev/null 2>&1; then
        echo "$input" | jq -r ".${field} // empty" 2>/dev/null || echo ""
    else
        # Fallback: basic grep/sed parsing (less reliable with complex JSON)
        echo "$input" | grep -o "\"${field}\":\"[^\"]*\"" | sed "s/\"${field}\":\"//; s/\"$//" | head -n1 || echo ""
    fi
}

# Read JSON from stdin
INPUT=$(cat)

# Parse JSON fields
HOOK_EVENT=$(parse_json "$INPUT" "hook_event_name")
MESSAGE=$(parse_json "$INPUT" "message")

# Check for Telegram credentials
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "⚠️ Telegram notification skipped: Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
    exit 0
fi

# Common variables
PROJECT_DIR="$(basename "$(pwd)")"
TIMESTAMP="$(date '+%H:%M:%S')"
DATE="$(date '+%Y-%m-%d')"
CURRENT_TIME="$(date +%s)"

# Calculate duration if session start exists
if [[ -f ~/.claude/session_start.tmp ]]; then
    START_TIME="$(cat ~/.claude/session_start.tmp)"
    DURATION="$((CURRENT_TIME - START_TIME))"

    # Sanity check: if duration > 24 hours (86400 seconds), likely invalid
    if [[ $DURATION -gt 86400 ]]; then
        DURATION_TEXT="N/A (stale session)"
    else
        MINUTES="$((DURATION / 60))"
        SECONDS="$((DURATION % 60))"
        DURATION_TEXT="${MINUTES}m ${SECONDS}s"
    fi
else
    DURATION_TEXT="N/A"
fi

# Determine notification type and construct message
case "$HOOK_EVENT" in
    "SessionStart")
        # Session started - create timestamp file
        echo "$CURRENT_TIME" > ~/.claude/session_start.tmp
        EMOJI="🚀"
        TITLE="Claude Code Session Started"
        TELEGRAM_MESSAGE="$EMOJI <b>$TITLE</b>%0A📁 Project: $(url_encode "$PROJECT_DIR")%0A⏰ Time: $TIMESTAMP%0A📅 Date: $DATE"

        # macOS desktop notification
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"Project: $PROJECT_DIR\" with title \"🚀 Session Started\"" 2>/dev/null || true
        fi
        ;;

    "Notification")
        # Parse notification message to determine specific type
        if echo "$MESSAGE" | grep -qiE "(permission|approve|allow)"; then
            # Tool approval request
            EMOJI="🔐"
            TITLE="Tool Approval Required"
            DETAILS="Claude is requesting permission to use a tool"
        elif echo "$MESSAGE" | grep -qiE "(waiting|idle|input)"; then
            # Waiting for input
            EMOJI="⏳"
            TITLE="Waiting for Input"
            DETAILS="Claude has been idle (60+ seconds)"
        else
            # Generic notification
            EMOJI="🔔"
            TITLE="Notification"
            # Truncate message if too long (at word boundary)
            if [[ ${#MESSAGE} -gt 100 ]]; then
                DETAILS="${MESSAGE:0:100}..."
            else
                DETAILS="$MESSAGE"
            fi
        fi

        TELEGRAM_MESSAGE="$EMOJI <b>$TITLE</b>%0A📁 Project: $(url_encode "$PROJECT_DIR")%0A📝 $(url_encode "$DETAILS")%0A⏰ Time: $TIMESTAMP%0A📅 Date: $DATE"

        # macOS desktop notification
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"$DETAILS\" with title \"$EMOJI $TITLE\"" 2>/dev/null || true
        fi
        ;;

    "Stop")
        # Main task completion
        EMOJI="✅"
        TITLE="Task Completed"
        TELEGRAM_MESSAGE="$EMOJI <b>$TITLE</b>%0A📁 Project: $(url_encode "$PROJECT_DIR")%0A⏱️ Duration: $DURATION_TEXT%0A⏰ Finished: $TIMESTAMP%0A📅 Date: $DATE"

        # macOS desktop notification
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"Duration: $DURATION_TEXT\" with title \"✅ Task Completed\"" 2>/dev/null || true
        fi
        ;;

    "SubagentStop")
        # Subagent completion
        EMOJI="🤖"
        TITLE="Subagent Task Completed"
        TELEGRAM_MESSAGE="$EMOJI <b>$TITLE</b>%0A📁 Project: $(url_encode "$PROJECT_DIR")%0A⏱️ Duration: $DURATION_TEXT%0A⏰ Finished: $TIMESTAMP%0A📅 Date: $DATE"

        # macOS desktop notification
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"Duration: $DURATION_TEXT\" with title \"🤖 Subagent Completed\"" 2>/dev/null || true
        fi
        ;;

    "SessionEnd")
        # Session ended
        EMOJI="🏁"
        TITLE="Session Ended"
        TELEGRAM_MESSAGE="$EMOJI <b>$TITLE</b>%0A📁 Project: $(url_encode "$PROJECT_DIR")%0A⏱️ Total Duration: $DURATION_TEXT%0A⏰ Time: $TIMESTAMP%0A📅 Date: $DATE"

        # macOS desktop notification
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"Total Duration: $DURATION_TEXT\" with title \"🏁 Session Ended\"" 2>/dev/null || true
        fi

        # Clean up session start file
        rm -f ~/.claude/session_start.tmp
        ;;

    *)
        # Unknown event type - log it for debugging
        EMOJI="ℹ️"
        TITLE="Unknown Event"
        MSG_PREVIEW="${MESSAGE:0:100}"
        [[ ${#MESSAGE} -gt 100 ]] && MSG_PREVIEW="${MSG_PREVIEW}..."
        TELEGRAM_MESSAGE="$EMOJI <b>Claude Code Event</b>%0A📁 Project: $(url_encode "$PROJECT_DIR")%0A🔖 Event: $(url_encode "$HOOK_EVENT")%0A📝 Message: $(url_encode "$MSG_PREVIEW")%0A⏰ Time: $TIMESTAMP%0A📅 Date: $DATE"

        # macOS desktop notification (optional for debugging)
        if command -v osascript >/dev/null 2>&1; then
            osascript -e "display notification \"Event: $HOOK_EVENT\" with title \"ℹ️ Unknown Event\"" 2>/dev/null || true
        fi
        ;;
esac

# Send Telegram notification with retry logic
send_telegram_notification() {
    local max_retries=3
    local retry_delay=2
    local attempt=1

    while [[ $attempt -le $max_retries ]]; do
        # Send with 10-second timeout
        HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null --max-time 10 -X POST \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" \
            -d "text=$TELEGRAM_MESSAGE" \
            -d "parse_mode=HTML" 2>/dev/null)

        # Check if curl succeeded
        CURL_EXIT=$?
        if [[ $CURL_EXIT -eq 0 && "$HTTP_CODE" =~ ^2 ]]; then
            echo "✅ Telegram notification sent: $TITLE ($HOOK_EVENT)"
            return 0
        fi

        # Handle failure
        if [[ $CURL_EXIT -ne 0 ]]; then
            echo "⚠️ Attempt $attempt failed: curl error (exit code $CURL_EXIT)"
        else
            echo "⚠️ Attempt $attempt failed: HTTP $HTTP_CODE"
        fi

        # Retry if not last attempt
        if [[ $attempt -lt $max_retries ]]; then
            echo "   Retrying in ${retry_delay}s..."
            sleep $retry_delay
            ((attempt++))
        else
            echo "❌ Failed to send Telegram notification after $max_retries attempts"
            return 1
        fi
    done
}

send_telegram_notification

# Exit gracefully even if notification fails (don't block Claude Code)
exit 0
