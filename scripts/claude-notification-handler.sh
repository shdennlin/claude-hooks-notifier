#!/usr/bin/env bash
# Claude Code Notification Handler for Telegram
# Sends different notifications based on hook event type and context

set -euo pipefail

# Keep stdout for hook JSON only: SessionStart feeds plain stdout to Claude as
# context, so diagnostics go to stderr and JSON is written to fd 3
exec 3>&1 1>&2

# Escape text for Telegram HTML parse_mode
html_escape() {
    # sed instead of ${var//}: bash 5.2+ treats & in the replacement as the match
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Truncate to N characters with "..." (UTF-8 locale so CJK text is never
# cut mid-character, which Telegram would reject)
truncate_text() {
    local LC_ALL=en_US.UTF-8
    local text="$1" max="$2"
    if [[ ${#text} -gt $max ]]; then
        printf '%s...' "${text:0:$max}"
    else
        printf '%s' "$text"
    fi
}

# Escape text for embedding in an AppleScript string literal
applescript_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
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
NOTIFICATION_TYPE=$(parse_json "$INPUT" "notification_type")
# StopFailure: the live payload carries `error` (e.g. authentication_failed);
# the docs list error_type/error_message instead, so accept either
ERROR_TYPE=$(parse_json "$INPUT" "error")
[[ -z "$ERROR_TYPE" ]] && ERROR_TYPE=$(parse_json "$INPUT" "error_type")
ERROR_TEXT=$(parse_json "$INPUT" "error_message")
HOOK_CWD=$(parse_json "$INPUT" "cwd")
TRANSCRIPT_PATH=$(parse_json "$INPUT" "transcript_path")
SESSION_TITLE_INPUT=$(parse_json "$INPUT" "session_title")
SESSION_ID=$(parse_json "$INPUT" "session_id")
SOURCE=$(parse_json "$INPUT" "source")
LAST_MESSAGE=$(parse_json "$INPUT" "last_assistant_message")

# Config precedence: plugin userConfig (CLAUDE_PLUGIN_OPTION_*) > legacy env vars > default
TELEGRAM_BOT_TOKEN="${CLAUDE_PLUGIN_OPTION_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
TELEGRAM_CHAT_ID="${CLAUDE_PLUGIN_OPTION_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"

# Notification toggles (set to "false" to disable)
ENABLE_TELEGRAM="${CLAUDE_PLUGIN_OPTION_NOTIFY_TELEGRAM:-${CLAUDE_NOTIFY_TELEGRAM:-true}}"
ENABLE_DESKTOP="${CLAUDE_PLUGIN_OPTION_NOTIFY_DESKTOP:-${CLAUDE_NOTIFY_DESKTOP:-true}}"
ENABLE_AUTO_TITLE="${CLAUDE_PLUGIN_OPTION_NOTIFY_AUTO_TITLE:-${CLAUDE_NOTIFY_AUTO_TITLE:-true}}"
ENABLE_PREVIEW="${CLAUDE_PLUGIN_OPTION_NOTIFY_MESSAGE_PREVIEW:-${CLAUDE_NOTIFY_MESSAGE_PREVIEW:-true}}"

# Resolve session name: SessionStart's session_title input, then the latest
# /rename title, then the auto-generated title from the transcript JSONL
get_session_title() {
    if [[ -n "$SESSION_TITLE_INPUT" ]]; then
        echo "$SESSION_TITLE_INPUT"
        return 0
    fi
    [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local line
    line=$(grep '^{"type":"custom-title"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n1 || true)
    if [[ -n "$line" ]]; then
        echo "$line" | jq -r '.customTitle // empty' 2>/dev/null || true
        return 0
    fi
    line=$(grep '^{"type":"ai-title"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n1 || true)
    if [[ -n "$line" ]]; then
        echo "$line" | jq -r '.aiTitle // empty' 2>/dev/null || true
    fi
    return 0
}

# Auto session name from the git branch; empty on main/master/detached HEAD
# so Claude's own ai-title is not overridden by a meaningless name
get_auto_title() {
    local branch
    branch=$(git -C "${HOOK_CWD:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    case "$branch" in
        ""|HEAD|main|master) return 0 ;;
    esac
    echo "$branch"
}

SESSION_TITLE="$(get_session_title)"

# Name new sessions automatically (same effect as /rename); runs before the
# toggle checks so it works even with notifications disabled
if [[ "$HOOK_EVENT" == "SessionStart" && "$SOURCE" == "startup" && "$ENABLE_AUTO_TITLE" == "true" \
      && -z "$SESSION_TITLE_INPUT" ]] && command -v jq >/dev/null 2>&1; then
    AUTO_TITLE="$(get_auto_title)"
    if [[ -n "$AUTO_TITLE" ]]; then
        SESSION_TITLE="$AUTO_TITLE"
        jq -nc --arg t "$AUTO_TITLE" \
            '{hookSpecificOutput: {hookEventName: "SessionStart", sessionTitle: $t}}' >&3
    fi
fi

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
PROJECT_DIR="$(basename "${HOOK_CWD:-$(pwd)}")"
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

# Telegram header: bold project name, plus italic session name when known
TELEGRAM_HEADER="<b>$(html_escape "$PROJECT_DIR")</b>"
[[ -n "$SESSION_TITLE" ]] && TELEGRAM_HEADER+=" · <i>$(html_escape "$SESSION_TITLE")</i>"

# Helper: send macOS desktop notification (respects ENABLE_DESKTOP toggle)
# Usage: send_desktop_notification "title" "message" ["sound"]
send_desktop_notification() {
    [[ "$ENABLE_DESKTOP" != "true" ]] && return 0

    local title="$1"
    local message="$2"
    local sound="${3:-}"

    if command -v terminal-notifier >/dev/null 2>&1; then
        local args=(-title "$title" -message "$message" -activate "$TERMINAL_BUNDLE_ID")
        [[ -n "$SESSION_TITLE" ]] && args+=(-subtitle "$SESSION_TITLE")
        [[ -n "$sound" ]] && args+=(-sound "$sound")
        terminal-notifier "${args[@]}" 2>/dev/null || true
    elif command -v osascript >/dev/null 2>&1; then
        local script="display notification \"$(applescript_escape "$message")\" with title \"$(applescript_escape "$title")\""
        [[ -n "$SESSION_TITLE" ]] && script="$script subtitle \"$(applescript_escape "$SESSION_TITLE")\""
        [[ -n "$sound" ]] && script="$script sound name \"$sound\""
        osascript -e "$script" 2>/dev/null || true
    fi
}

# Per-session start file so concurrent sessions don't clobber each other
SESSION_START_FILE="$HOME/.claude/session_start.${SESSION_ID:-default}.tmp"

# Session duration, only when this session's start time is known
DURATION_TEXT=""
if [[ -f "$SESSION_START_FILE" ]]; then
    START_TIME="$(cat "$SESSION_START_FILE" 2>/dev/null || echo "")"
    if [[ "$START_TIME" =~ ^[0-9]+$ ]]; then
        DURATION="$((CURRENT_TIME - START_TIME))"
        # Sanity check: ignore durations over 24 hours (stale file)
        if [[ $DURATION -ge 0 && $DURATION -le 86400 ]]; then
            DURATION_TEXT="$((DURATION / 60))m $((DURATION % 60))s"
        fi
    fi
fi

# First meaningful line of Claude's final message, stripped of markdown
# (the text leaves the machine via Telegram; disable with CLAUDE_NOTIFY_MESSAGE_PREVIEW=false)
PREVIEW=""
if [[ "$ENABLE_PREVIEW" == "true" && -n "$LAST_MESSAGE" ]]; then
    PREVIEW=$(printf '%s\n' "$LAST_MESSAGE" \
        | sed -E 's/^[[:space:]#>*`-]+//; s/`|\*\*//g; /^[[:space:]]*$/d' | head -n1 || true)
    PREVIEW="$(truncate_text "$PREVIEW" 120)"
fi

# Full reply for Telegram, shown in a collapsed blockquote the reader can expand;
# capped well below Telegram's 4096-char message limit to leave room for the header
FULL_REPLY=""
if [[ "$ENABLE_PREVIEW" == "true" && -n "$LAST_MESSAGE" ]]; then
    FULL_REPLY=$(printf '%s\n' "$LAST_MESSAGE" \
        | sed -E 's/`|\*\*//g' | sed -e '/./,$!d' | cat -s || true)
    FULL_REPLY="${FULL_REPLY%$'\n'}"
    FULL_REPLY="$(truncate_text "$FULL_REPLY" 3500)"
fi

# Append the full reply as an expandable blockquote (collapsed, it shows the first lines)
add_reply() {
    [[ -n "$FULL_REPLY" ]] && TELEGRAM_MESSAGE+=$'\n'"<blockquote expandable>$(html_escape "$FULL_REPLY")</blockquote>"
    return 0
}

# Append "⏱ duration" and the expandable reply to a notification
add_details() {
    [[ -n "$DURATION_TEXT" ]] && TELEGRAM_MESSAGE+=$'\n'"⏱ $DURATION_TEXT"
    add_reply
}

# Determine notification type and construct message
case "$HOOK_EVENT" in
    "SessionStart")
        # Session started - create timestamp file, drop ones from dead sessions.
        # Silent on purpose: the hook still runs for the start time (the
        # duration on Task Complete / Session Ended) and the auto title above.
        find "$HOME/.claude" -maxdepth 1 -name 'session_start.*.tmp' -mtime +1 -delete 2>/dev/null || true
        echo "$CURRENT_TIME" > "$SESSION_START_FILE"
        exit 0
        ;;

    "Notification")
        # Parse notification message to determine specific type
        # An MCP elicitation asks for input, whatever its wording, so it must
        # not be taken for a permission request by the message match below
        IS_ELICITATION="false"
        case "$NOTIFICATION_TYPE" in
            elicitation_dialog|elicitation_url_dialog) IS_ELICITATION="true" ;;
        esac

        IS_PERMISSION="false"
        if [[ "$IS_ELICITATION" != "true" ]] && { [[ "$NOTIFICATION_TYPE" == "permission_prompt" ]] || echo "$MESSAGE" | grep -qiE "(permission|approve|allow)"; }; then
            IS_PERMISSION="true"
        fi

        if [[ "$IS_PERMISSION" == "true" ]]; then
            # Tool approval request - HIGHEST PRIORITY
            EMOJI="🔐"
            ACTION="Tool Approval Needed"
            DETAILS="Claude is requesting permission to use a tool"
        elif [[ "$IS_ELICITATION" == "true" ]]; then
            # An MCP server is asking the user to fill in a form or open a URL
            EMOJI="📝"
            ACTION="Input Requested"
            DETAILS="$(truncate_text "$MESSAGE" 100)"
        elif [[ "$NOTIFICATION_TYPE" == "agent_needs_input" ]]; then
            # A background agent is blocked on the user
            EMOJI="🙋"
            ACTION="Agent Needs Input"
            DETAILS="$(truncate_text "$MESSAGE" 100)"
        else
            # Generic notification
            EMOJI="🔔"
            ACTION="Notification"
            DETAILS="$(truncate_text "$MESSAGE" 100)"
        fi

        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $ACTION"$'\n'"$(html_escape "$DETAILS")"
        if [[ "$IS_PERMISSION" == "true" || "$IS_ELICITATION" == "true" || "$NOTIFICATION_TYPE" == "agent_needs_input" ]]; then
            send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION - $DETAILS" "Basso"
        else
            send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION - $DETAILS"
        fi
        ;;

    "Stop")
        # Main task completion
        EMOJI="✅"
        ACTION="Task Complete"
        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $ACTION"
        add_details
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION${PREVIEW:+ - $PREVIEW}" "Hero"
        ;;

    "StopFailure")
        # The turn ended on an API error, so Stop never fires for it
        EMOJI="⚠️"
        ACTION="Task Failed"
        # The error kind, then the human text (last_assistant_message holds it
        # in the live payload, e.g. "Failed to authenticate. API Error: 401 ...")
        DETAILS="$ERROR_TYPE"
        FAIL_TEXT="${ERROR_TEXT:-$LAST_MESSAGE}"
        [[ -n "$FAIL_TEXT" ]] && DETAILS="${DETAILS:+$DETAILS - }$FAIL_TEXT"
        DETAILS="$(truncate_text "${DETAILS:-$MESSAGE}" 100)"
        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $ACTION"
        [[ -n "$DETAILS" ]] && TELEGRAM_MESSAGE+=$'\n'"$(html_escape "$DETAILS")"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION${DETAILS:+ - $DETAILS}" "Basso"
        ;;

    "SessionEnd")
        # Session ended
        EMOJI="🏁"
        ACTION="Session Ended"
        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $ACTION"
        [[ -n "$DURATION_TEXT" ]] && TELEGRAM_MESSAGE+=$'\n'"⏱ $DURATION_TEXT"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION${DURATION_TEXT:+ (⏱ $DURATION_TEXT)}" "Submarine"

        # Clean up session start file
        rm -f "$SESSION_START_FILE"
        ;;

    *)
        # Unknown event type - log it for debugging
        EMOJI="ℹ️"
        ACTION="Unknown Event: $HOOK_EVENT"
        MSG_PREVIEW="$(truncate_text "$MESSAGE" 80)"
        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $(html_escape "$ACTION")"$'\n'"$(html_escape "$MSG_PREVIEW")"
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
            --data-urlencode "text=$TELEGRAM_MESSAGE" \
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
