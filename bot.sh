#!/usr/bin/env bash
set -euo pipefail

BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
MESSAGE_THREAD_ID="${MESSAGE_THREAD_ID:-}"
TIMER_INTERVAL="${TIMER_INTERVAL:-10}"

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "Error: BOT_TOKEN or CHAT_ID not set." >&2
    exit 1
fi

API="https://api.telegram.org/bot${BOT_TOKEN}"

thread_args=()
if [[ -n "$MESSAGE_THREAD_ID" ]]; then
    thread_args=(-d message_thread_id="$MESSAGE_THREAD_ID")
fi

if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
    RUN_URL="https://github.com"
fi

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

fmt_elapsed() {
    printf '%dm %02ds' $(($1 / 60)) $(($1 % 60))
}

tg_post() {
    local method="$1"
    shift
    curl -s -m 15 -X POST "${API}/${method}" -d chat_id="$CHAT_ID" -d parse_mode="HTML" "$@"
}

commit_id=$(git log -1 --format='%h')
commit_text=$(git log -1 --format='%s')
commit_text=$(html_escape "${commit_text:0:150}")
start_time=$(date +%s)
msg_id=""
timer_pid=""

notify_failure() {
    local reason="$1" text keyboard
    text="${reason} at $(fmt_elapsed $(($(date +%s) - start_time)))"
    keyboard="{\"inline_keyboard\":[[{\"text\":\"Compilation\",\"url\":\"${RUN_URL}\"}]]}"

    if [[ -n "$msg_id" ]]; then
        tg_post editMessageText -d message_id="$msg_id" \
            --data-urlencode "text=${text}" \
            --data-urlencode "reply_markup=${keyboard}" > /dev/null 2>&1 || true
    else
        tg_post sendMessage "${thread_args[@]}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "reply_markup=${keyboard}" > /dev/null 2>&1 || true
    fi
}

initial_res=$(tg_post sendMessage "${thread_args[@]}" \
    --data-urlencode "text=<b>- Compiling Kernel</b>
• Elapsed: 0m 00s" || true)

msg_id=$(printf '%s' "$initial_res" | jq -r '.result.message_id // empty' 2>/dev/null || true)

if [[ -z "$msg_id" ]]; then
    echo "Warning: could not extract message_id, Telegram API said:" >&2
    echo "$initial_res" >&2
else
    (
        while true; do
            sleep "$TIMER_INTERVAL"
            elapsed=$(fmt_elapsed $(($(date +%s) - start_time)))
            tg_post editMessageText -m 10 -d message_id="$msg_id" \
                --data-urlencode "text=<b>- Compiling Kernel</b>
• Elapsed: ${elapsed}" > /dev/null 2>&1 || true
        done
    ) &
    timer_pid=$!
fi

stop_timer() {
    if [[ -n "$timer_pid" ]]; then
        kill "$timer_pid" 2>/dev/null || true
        wait "$timer_pid" 2>/dev/null || true
        timer_pid=""
    fi
}

on_interrupt() {
    stop_timer
    notify_failure "Compilation Interrupted"
    exit 1
}
trap stop_timer EXIT
trap on_interrupt INT TERM

export SKIP_UPLOAD=1

if ./sashimi.sh -v bangkk; then
    stop_timer
    duration=$(fmt_elapsed $(($(date +%s) - start_time)))

    if [[ -n "$msg_id" ]]; then
        tg_post deleteMessage -d message_id="$msg_id" > /dev/null 2>&1 || true
    fi

    shopt -s nullglob
    zips=( Sashimi-*.zip )
    shopt -u nullglob

    if [[ ${#zips[@]} -gt 0 ]]; then
        zip_file=$(ls -t "${zips[@]}" | head -n 1)

        case "$zip_file" in
            Sashimi-ksu-*) ksu_status="Yes" ;;
            *) ksu_status="No" ;;
        esac

        caption="🍣 Sashimi Kernel (bangkk)
• Commit: ${commit_id}
• Message: ${commit_text}
• ReSukiSU: ${ksu_status}
• Duration: ${duration} (<a href=\"${RUN_URL}\">Workflow</a>)"

        if ! curl -s -f -m 300 --retry 3 --retry-delay 5 \
            -F chat_id="$CHAT_ID" \
            -F document=@"$zip_file" \
            ${MESSAGE_THREAD_ID:+-F message_thread_id="$MESSAGE_THREAD_ID"} \
            --form-string caption="$caption" \
            --form-string parse_mode="HTML" \
            "${API}/sendDocument" > /dev/null; then
            echo "Warning: build succeeded but Telegram upload failed." >&2
            tg_post sendMessage "${thread_args[@]}" \
                --data-urlencode "text=Build succeeded (${zip_file}) but upload to Telegram failed. Check the <a href=\"${RUN_URL}\">workflow</a> artifacts." \
                > /dev/null 2>&1 || true
        fi
    else
        echo "Warning: Build succeeded but no .zip output was found." >&2
    fi

    exit 0
else
    stop_timer
    notify_failure "Compilation Failed"
    echo "Build failed." >&2
    exit 1
fi
