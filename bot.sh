#!/usr/bin/env bash
set -eo pipefail

if [[ -f ".env" ]]; then
    source .env
fi

BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
MESSAGE_THREAD_ID="${MESSAGE_THREAD_ID:-}"

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "Error: BOT_TOKEN or CHAT_ID not set." >&2
    exit 1
fi

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/${GITHUB_RUN_ID:+actions/runs/}${GITHUB_RUN_ID:-}"
if [[ -z "${GITHUB_RUN_ID:-}" ]]; then
    RUN_URL="https://github.com"
fi

commit_id=$(git log -1 --format='%h')
commit_text=$(git log -1 --format='%s')
start_time=$(date +%s)

initial_res=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    ${MESSAGE_THREAD_ID:+-d message_thread_id="$MESSAGE_THREAD_ID"} \
    -d parse_mode="HTML" \
    --data-urlencode "text=Compiling Kernel
Stage: Compiling Kernel
Status: 0m 00s")

msg_id=$(echo "$initial_res" | jq -r '.result.message_id // empty' 2>/dev/null || echo "$initial_res" | grep -oP '"message_id":\s*\K[0-9]+' | head -n 1)

if [[ -n "$msg_id" ]]; then
    (
        while true; do
            sleep 30
            now=$(date +%s)
            elapsed=$((now - start_time))
            m=$((elapsed / 60))
            s=$((elapsed % 60))
            status_time=$(printf "%dm %02ds" "$m" "$s")

            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/editMessageText" \
                -d chat_id="$CHAT_ID" \
                -d message_id="$msg_id" \
                -d parse_mode="HTML" \
                --data-urlencode "text=Compiling Kernel
Stage: Compiling Kernel
Status: ${status_time}" > /dev/null 2>&1 || true
        done
    ) &
    timer_pid=$!
fi

stop_timer() {
    if [[ -n "${timer_pid:-}" ]]; then
        kill "$timer_pid" 2>/dev/null || true
        wait "$timer_pid" 2>/dev/null || true
    fi
}
trap stop_timer EXIT

if ./sashimi.sh -v bangkk; then
    stop_timer
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    elapsed_minutes=$((elapsed_time / 60))
    elapsed_seconds=$((elapsed_time % 60))

    if [[ -n "$msg_id" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/deleteMessage" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$msg_id" > /dev/null 2>&1 || true
    fi

    shopt -s nullglob
    zips=( Sashimi-*.zip *.zip )
    shopt -u nullglob

    if [[ ${#zips[@]} -gt 0 ]]; then
        zip_file="${zips[0]}"

        caption="🍣 Sashimi Kernel (bangkk)
• Commit: ${commit_id}
• Message: ${commit_text}
• Duration: ${elapsed_minutes}m ${elapsed_seconds}s (<a href=\"${RUN_URL}\">Workflow</a>)"

        curl -s -f \
            -F chat_id="$CHAT_ID" \
            -F document=@"$zip_file" \
            ${MESSAGE_THREAD_ID:+-F message_thread_id="$MESSAGE_THREAD_ID"} \
            -F caption="$caption" \
            -F parse_mode="HTML" \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" > /dev/null
    else
        echo "Warning: Build succeeded but no .zip output was found." >&2
    fi

    exit 0
else
    stop_timer
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    elapsed_minutes=$((elapsed_time / 60))
    elapsed_seconds=$((elapsed_time % 60))

    fail_text="Compilation Failed at ${elapsed_minutes}m ${elapsed_seconds}s"
    keyboard="{\"inline_keyboard\":[[{\"text\":\"Compilation\",\"url\":\"${RUN_URL}\"}]]}"

    if [[ -n "$msg_id" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/editMessageText" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$msg_id" \
            -d parse_mode="HTML" \
            --data-urlencode "text=${fail_text}" \
            -d reply_markup="$keyboard" > /dev/null 2>&1 || true
    else
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="$CHAT_ID" \
            ${MESSAGE_THREAD_ID:+-d message_thread_id="$MESSAGE_THREAD_ID"} \
            -d parse_mode="HTML" \
            --data-urlencode "text=${fail_text}" \
            -d reply_markup="$keyboard" > /dev/null 2>&1 || true
    fi

    echo "Build failed." >&2
    exit 1
fi
