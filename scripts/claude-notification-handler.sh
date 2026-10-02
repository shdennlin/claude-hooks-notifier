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
HOOK_CWD=$(parse_json "$INPUT" "cwd")
TRANSCRIPT_PATH=$(parse_json "$INPUT" "transcript_path")
SESSION_TITLE_INPUT=$(parse_json "$INPUT" "session_title")
SESSION_ID=$(parse_json "$INPUT" "session_id")
SOURCE=$(parse_json "$INPUT" "source")
AGENT_TYPE=$(parse_json "$INPUT" "agent_type")
LAST_MESSAGE=$(parse_json "$INPUT" "last_assistant_message")

# Notification toggles (set to "false" to disable)
ENABLE_TELEGRAM="${CLAUDE_NOTIFY_TELEGRAM:-true}"
ENABLE_DESKTOP="${CLAUDE_NOTIFY_DESKTOP:-true}"
ENABLE_AUTO_TITLE="${CLAUDE_NOTIFY_AUTO_TITLE:-true}"
ENABLE_PREVIEW="${CLAUDE_NOTIFY_MESSAGE_PREVIEW:-true}"

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

# Append "⏱ duration" and the message preview to a notification
add_details() {
    [[ -n "$PREVIEW" ]] && TELEGRAM_MESSAGE+=$'\n'"$(html_escape "$PREVIEW")"
    [[ -n "$DURATION_TEXT" ]] && TELEGRAM_MESSAGE+=$'\n'"⏱ $DURATION_TEXT"
    return 0
}

# Determine notification type and construct message
case "$HOOK_EVENT" in
    "SessionStart")
        # Session started - create timestamp file, drop ones from dead sessions
        find "$HOME/.claude" -maxdepth 1 -name 'session_start.*.tmp' -mtime +1 -delete 2>/dev/null || true
        echo "$CURRENT_TIME" > "$SESSION_START_FILE"
        EMOJI="🚀"
        ACTION="Session Started"
        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $ACTION"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION" "Glass"
        ;;

    "Notification")
        # Parse notification message to determine specific type
        IS_PERMISSION="false"
        if [[ "$NOTIFICATION_TYPE" == "permission_prompt" ]] || echo "$MESSAGE" | grep -qiE "(permission|approve|allow)"; then
            IS_PERMISSION="true"
        fi

        if [[ "$IS_PERMISSION" == "true" ]]; then
            # Tool approval request - HIGHEST PRIORITY
            EMOJI="🔐"
            ACTION="Tool Approval Needed"
            DETAILS="Claude is requesting permission to use a tool"
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
        if [[ "$IS_PERMISSION" == "true" || "$NOTIFICATION_TYPE" == "agent_needs_input" ]]; then
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

    "SubagentStop")
        # Subagent completion
        EMOJI="🤖"
        ACTION="Subagent Task Complete${AGENT_TYPE:+ ($AGENT_TYPE)}"
        TELEGRAM_MESSAGE="$TELEGRAM_HEADER"$'\n'"$EMOJI $(html_escape "$ACTION")"
        [[ -n "$PREVIEW" ]] && TELEGRAM_MESSAGE+=$'\n'"$(html_escape "$PREVIEW")"
        send_desktop_notification "$PROJECT_DIR" "$EMOJI $ACTION${PREVIEW:+ - $PREVIEW}" "Purr"
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
    if [[ "$HOOK_EVENT" == "SessionStart" ]]; then
        # SessionStart hooks run synchronously (their output sets the title), so
        # detach the network call to avoid stalling startup on retries
        # (close fd 3 too: it is the hook's stdout and would keep the pipe open)
        ( send_telegram_notification </dev/null >/dev/null 2>&1 3>&- & )
    else
        send_telegram_notification || echo "⚠️ Telegram notification failed for $HOOK_EVENT event (non-fatal)" >&2
    fi
fi

# Exit gracefully even if notification fails (don't block Claude Code)
exit 0
