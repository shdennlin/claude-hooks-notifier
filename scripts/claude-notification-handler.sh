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

# Notification toggles (set to "false" to disable)
ENABLE_TELEGRAM="${CLAUDE_NOTIFY_TELEGRAM:-true}"
ENABLE_DESKTOP="${CLAUDE_NOTIFY_DESKTOP:-true}"

# Check for Telegram credentials
if [[ "$ENABLE_TELEGRAM" == "true" && ( -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ) ]]; then
    echo "⚠️ Telegram notification skipped: Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
    ENABLE_TELEGRAM="false"
fi

# Exit early if both are disabled
if [[ "$ENABLE_TELEGRAM" != "true" && "$ENABLE_DESKTOP" != "true" ]]; then
    echo "ℹ️ All notifications disabled"
    exit 0
fi

# Common variables
PROJECT_DIR="$(basename "$(pwd)")"
TIMESTAMP="$(date '+%H:%M:%S')"
DATE="$(date '+%Y-%m-%d')"
CURRENT_TIME="$(date +%s)"

# Detect which terminal app is running for click-to-activate
detect_terminal_bundle_id() {
    local term_program="${TERM_PROGRAM:-}"

    # Map TERM_PROGRAM to known bundle IDs
    case "$term_program" in
        "iTerm.app")       echo "com.googlecode.iterm2" ;;
        "ghostty")         echo "com.mitchellh.ghostty" ;;
        "Alacritty")       echo "org.alacritty" ;;
        "kitty")           echo "net.kovidgoyal.kitty" ;;
        "WezTerm")         echo "org.wezfurlong.wezterm" ;;
        "WarpTerminal")    echo "dev.warp.Warp-Stable" ;;
        "Hyper")           echo "co.zeit.hyper" ;;
        "tabby")           echo "org.tabby" ;;
        "rio")             echo "com.raphaelamorim.rio" ;;
        "vscode")          echo "com.microsoft.VSCode" ;;
        "Apple_Terminal")  echo "com.apple.Terminal" ;;
        *)
            # Fallback: try to get bundle ID of the frontmost app via osascript
            if command -v osascript >/dev/null 2>&1; then
                local frontmost
                frontmost=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || echo "")
                if [[ -n "$frontmost" ]]; then
                    echo "$frontmost"
                    return
                fi
            fi
            # Ultimate fallback
            echo "com.apple.Terminal"
            ;;
    esac
}

TERMINAL_BUNDLE_ID="$(detect_terminal_bundle_id)"

# Helper: send macOS desktop notification (respects ENABLE_DESKTOP toggle)
# Usage: send_desktop_notification "title" "message" ["sound"]
send_desktop_notification() {
    [[ "$ENABLE_DESKTOP" != "true" ]] && return 0

    local title="$1"
    local message="$2"
    local sound="${3:-}"

    if command -v terminal-notifier >/dev/null 2>&1; then
        local args=(-title "$title" -message "$message" -activate "$TERMINAL_BUNDLE_ID")
        [[ -n "$sound" ]] && args+=(-sound "$sound")
        terminal-notifier "${args[@]}" 2>/dev/null || true
    elif command -v osascript >/dev/null 2>&1; then
        local script="display notification \"$message\" with title \"$title\""
        [[ -n "$sound" ]] && script="$script sound name \"$sound\""
        osascript -e "$script" 2>/dev/null || true
    fi
}

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
        ACTION="Session Started"
        TELEGRAM_MESSAGE="<b>$PROJECT_DIR</b>%0A$EMOJI $ACTION"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION" "Glass"
        ;;

    "Notification")
        # Parse notification message to determine specific type
        if echo "$MESSAGE" | grep -qiE "(permission|approve|allow)"; then
            # Tool approval request - HIGHEST PRIORITY
            EMOJI="🔐"
            ACTION="Tool Approval Needed"
            DETAILS="Claude is requesting permission to use a tool"
        else
            # Generic notification
            EMOJI="🔔"
            ACTION="Notification"
            # Truncate message if too long (at word boundary)
            if [[ ${#MESSAGE} -gt 100 ]]; then
                DETAILS="${MESSAGE:0:100}..."
            else
                DETAILS="$MESSAGE"
            fi
        fi

        TELEGRAM_MESSAGE="<b>$PROJECT_DIR</b>%0A$EMOJI $ACTION%0A$(url_encode "$DETAILS")"
        if echo "$MESSAGE" | grep -qiE "(permission|approve|allow)"; then
            send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION - $DETAILS" "Basso"
        else
            send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION - $DETAILS"
        fi
        ;;

    "Stop")
        # Main task completion
        EMOJI="✅"
        ACTION="Task Complete"
        TELEGRAM_MESSAGE="<b>$PROJECT_DIR</b>%0A$EMOJI $ACTION"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION" "Hero"
        ;;

    "SubagentStop")
        # Subagent completion
        EMOJI="🤖"
        ACTION="Subagent Task Complete"
        TELEGRAM_MESSAGE="<b>$PROJECT_DIR</b>%0A$EMOJI $ACTION"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION" "Purr"
        ;;

    "SessionEnd")
        # Session ended
        EMOJI="🏁"
        ACTION="Session Ended"
        TELEGRAM_MESSAGE="<b>$PROJECT_DIR</b>%0A$EMOJI $ACTION"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION" "Submarine"

        # Clean up session start file
        rm -f ~/.claude/session_start.tmp
        ;;

    *)
        # Unknown event type - log it for debugging
        EMOJI="ℹ️"
        ACTION="Unknown Event: $HOOK_EVENT"
        MSG_PREVIEW="${MESSAGE:0:80}"
        [[ ${#MESSAGE} -gt 80 ]] && MSG_PREVIEW="${MSG_PREVIEW}..."
        TELEGRAM_MESSAGE="<b>$PROJECT_DIR</b>%0A$EMOJI $ACTION%0A$(url_encode "$MSG_PREVIEW")"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION"
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
            echo "✅ Telegram notification sent: $ACTION ($HOOK_EVENT)"
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

if [[ "$ENABLE_TELEGRAM" == "true" ]]; then
    send_telegram_notification || echo "⚠️ Telegram notification failed for $HOOK_EVENT event (non-fatal)" >&2
fi

# Exit gracefully even if notification fails (don't block Claude Code)
exit 0
