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

commit_id=$(git log -1 --format='%h')
commit_text=$(git log -1 --format='%s')

start_time=$(date +%s)

if ./sashimi.sh -v bangkk; then
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    elapsed_minutes=$((elapsed_time / 60))
    elapsed_seconds=$((elapsed_time % 60))

    shopt -s nullglob
    zips=( Sashimi-*.zip *.zip )
    shopt -u nullglob

    if [[ ${#zips[@]} -gt 0 ]]; then
        zip_file="${zips[0]}"

        caption="🍣 Sashimi Kernel (bangkk)
• Commit: ${commit_id}
• Message: ${commit_text}
• Duration: ${elapsed_minutes}m ${elapsed_seconds}s"

        curl -s -f \
            -F chat_id="$CHAT_ID" \
            -F document=@"$zip_file" \
            ${MESSAGE_THREAD_ID:+-F message_thread_id="$MESSAGE_THREAD_ID"} \
            -F caption="$caption" \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" > /dev/null
    else
        echo "Warning: Build succeeded but no .zip output was found." >&2
    fi

    exit 0
else
    echo "Build failed." >&2
    exit 1
fi
