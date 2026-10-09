#!/usr/bin/env bash

set -Eeuo pipefail

BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
MESSAGE_THREAD_ID="${MESSAGE_THREAD_ID:-}"
TIMER_INTERVAL="${TIMER_INTERVAL:-10}"

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
	printf 'Error: BOT_TOKEN or CHAT_ID not set.\n' >&2
	exit 1
fi

[[ "$TIMER_INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
	printf 'Error: TIMER_INTERVAL must be a positive integer.\n' >&2
	exit 1
}
if [[ -n "$MESSAGE_THREAD_ID" && ! "$MESSAGE_THREAD_ID" =~ ^[1-9][0-9]*$ ]]; then
	printf 'Error: MESSAGE_THREAD_ID must be a positive integer.\n' >&2
	exit 1
fi

for tool in curl jq git date sleep stat setsid rm mktemp; do
	command -v "$tool" > /dev/null || {
		printf 'Error: %s not found.\n' "$tool" >&2
		exit 1
	}
done

[[ -x ./sashimi.sh ]] || {
	printf 'Error: sashimi.sh is missing or not executable.\n' >&2
	exit 1
}

API="https://api.telegram.org/bot${BOT_TOKEN}"
thread_args=()
document_thread_args=()
if [[ -n "$MESSAGE_THREAD_ID" ]]; then
	thread_args=(--data-urlencode "message_thread_id=$MESSAGE_THREAD_ID")
	document_thread_args=(--form-string "message_thread_id=$MESSAGE_THREAD_ID")
fi

if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
	RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
	RUN_URL="https://github.com"
fi

html_escape() {
	printf '%s' "$1" | jq -Rrs '@html'
}

fmt_elapsed() {
	local elapsed=$1
	(( elapsed >= 0 )) || elapsed=0
	printf '%dm %02ds' "$((elapsed / 60))" "$((elapsed % 60))"
}

tg_request() {
	local method=$1 response http_code description retry_after status attempt
	shift
	for ((attempt = 0; attempt < 3; attempt++)); do
		if response=$(curl -sS "$@" --write-out '\n%{http_code}' "${API}/${method}" 2>/dev/null); then
			status=0
		else
			status=$?
		fi
		if (( status != 0 )); then
			printf 'Warning: Telegram %s transport failed (curl %s).\n' "$method" "$status" >&2
			return 1
		fi
		http_code=${response##*$'\n'}
		response=${response%$'\n'*}
		if [[ "$http_code" == 200 ]] && printf '%s' "$response" | jq -e '.ok == true' > /dev/null 2>&1; then
			printf '%s' "$response"
			return 0
		fi
		if [[ "$method" == editMessageText && "$http_code" == 400 ]] && printf '%s' "$response" | \
			jq -e '.error_code == 400 and (.description // "" | contains("message is not modified"))' > /dev/null 2>&1; then
			printf '%s' "$response"
			return 0
		fi
		retry_after=$(printf '%s' "$response" | jq -r '.parameters.retry_after // empty' 2>/dev/null) || retry_after=""
		if [[ "$http_code" == 429 && "$retry_after" =~ ^[1-9][0-9]*$ ]] && (( ${#retry_after} <= 2 && 10#$retry_after <= 60 && attempt < 2 )); then
			printf 'Warning: Telegram %s rate limited; retrying in %s seconds.\n' "$method" "$retry_after" >&2
			sleep "$retry_after"
			continue
		fi
		description=$(printf '%s' "$response" | jq -r '(.description // "Invalid API response") | tostring | gsub("[\\r\\n]"; " ")' 2>/dev/null) || description="Invalid API response"
		description=${description//"$BOT_TOKEN"/'[redacted]'}
		printf 'Warning: Telegram %s failed (HTTP %s): %.240s\n' "$method" "$http_code" "$description" >&2
		return 1
	done
	return 1
}

tg_post() {
	local method=$1 timeout=15
	local parse_args=()
	shift
	case "$method" in
		sendMessage|editMessageText) parse_args=(--data-urlencode 'parse_mode=HTML') ;;
	esac
	[[ "$method" != editMessageText ]] || timeout=10
	tg_request "$method" --connect-timeout 10 --max-time "$timeout" -X POST \
		--data-urlencode "chat_id=$CHAT_ID" "${parse_args[@]}" "$@"
}

progress_text() {
	local started=$1 progress=0 stage=preparing label filled bar="" i elapsed
	if [[ -r "$SASHIMI_PROGRESS_FILE" ]]; then
		read -r progress stage < "$SASHIMI_PROGRESS_FILE" || true
	fi
	case "$progress" in
		0|20|40|80|100) ;;
		*) progress=0 ;;
	esac
	case "$stage" in
		toolchain) label="Toolchain setup" ;;
		configuration) label="Kernel configuration" ;;
		compilation) label="Kernel compilation" ;;
		packaging) label="ZIP packaging" ;;
		complete) label="Build completed" ;;
		*) label="Preparing build" ;;
	esac
	filled=$((progress / 10))
	for ((i = 0; i < 10; i++)); do
		if ((i < filled)); then
			bar+="🟩"
		else
			bar+="⬜"
		fi
	done
	elapsed=$(fmt_elapsed "$(($(date +%s) - started))")
	printf '<b>- Compiling Kernel</b>\n%s\n• Stage progress: %s%%\n• Stage: %s\n• Elapsed: %s' \
		"$bar" "$progress" "$label" "$elapsed"
}

timer_loop() {
	local id=$1 started=$2 interval=$3 text
	while true; do
		sleep "$interval"
		text=$(progress_text "$started")
		tg_post editMessageText --data-urlencode "message_id=$id" \
			--data-urlencode "text=$text" > /dev/null || true
	done
}

commit_id=$(git log -1 --format='%h')
commit_text=$(git log -1 --format='%s')
commit_id=$(html_escape "$commit_id")
commit_text=$(html_escape "${commit_text:0:150}")
run_url_html=$(html_escape "$RUN_URL")
keyboard=$(jq -cn --arg url "$RUN_URL" '{inline_keyboard: [[{text: "Compilation", url: $url}]]}')
start_time=$(date +%s)
msg_id=""
timer_pid=""
build_pid=""
message_file="${RUNNER_TEMP:-/tmp}/tg_msg_id"
finished=0
progress_dir=""
SASHIMI_PROGRESS_FILE=""

stop_group() {
	local pid=$1
	if [[ -n "$pid" ]]; then
		kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
}

stop_timer() {
	stop_group "$timer_pid"
	timer_pid=""
}

notify_failure() {
	local reason=$1 text
	text="${reason} at $(fmt_elapsed "$(($(date +%s) - start_time))")"
	if [[ -n "$msg_id" ]] && tg_post editMessageText \
		--data-urlencode "message_id=$msg_id" \
		--data-urlencode "text=$text" \
		--data-urlencode "reply_markup=$keyboard" > /dev/null; then
		return 0
	fi
	tg_post sendMessage "${thread_args[@]}" --data-urlencode "text=$text" \
		--data-urlencode "reply_markup=$keyboard" > /dev/null || true
}

cleanup() {
	local status=$?
	trap - EXIT
	stop_timer
	stop_group "$build_pid"
	if [[ -n "$progress_dir" ]]; then
		rm -rf -- "$progress_dir" || true
	fi
	exit "$status"
}

on_interrupt() {
	local status=$1
	trap '' INT TERM
	stop_timer
	stop_group "$build_pid"
	build_pid=""
	notify_failure "Compilation Interrupted"
	finished=1
	exit "$status"
}

on_error() {
	local status=$1
	trap - ERR
	stop_timer
	stop_group "$build_pid"
	build_pid=""
	if [[ "$finished" == 0 ]]; then
		notify_failure "Compilation Failed"
	fi
	printf 'Error: bot failed (exit %s).\n' "$status" >&2
	exit "$status"
}

trap cleanup EXIT
trap 'on_error "$?"' ERR
trap 'on_interrupt 130' INT
trap 'on_interrupt 143' TERM

progress_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/sashimi-progress.XXXXXX")
export SASHIMI_PROGRESS_FILE="$progress_dir/status"
printf '0 preparing\n' > "$SASHIMI_PROGRESS_FILE"

declare -A previous_zips=()
shopt -s nullglob
for file in Sashimi-*.zip; do
	if [[ -f "$file" ]]; then
		previous_zips["$file"]=$(stat -c '%i:%s:%y' -- "$file")
	fi
done

if initial_res=$(tg_post sendMessage "${thread_args[@]}" \
	--data-urlencode "text=$(progress_text "$start_time")"); then
	msg_id=$(printf '%s' "$initial_res" | jq -r '.result.message_id | select(type == "number" and . > 0 and . == floor)' 2>/dev/null || true)
fi

if [[ -n "$msg_id" ]]; then
	if ! printf '%s\n' "$msg_id" > "$message_file"; then
		printf 'Warning: could not save Telegram message ID.\n' >&2
	fi
	export API BOT_TOKEN CHAT_ID
	export -f tg_request tg_post fmt_elapsed progress_text timer_loop
	setsid "$BASH" -c 'timer_loop "$@"' _ "$msg_id" "$start_time" "$TIMER_INTERVAL" &
	timer_pid=$!
else
	printf 'Warning: Telegram progress notification failed; continuing build.\n' >&2
fi

export SKIP_UPLOAD=1
setsid ./sashimi.sh -v bangkk &
build_pid=$!
if wait "$build_pid"; then
	build_status=0
else
	build_status=$?
fi
build_pid=""
stop_timer

if [[ "$build_status" != 0 ]]; then
	notify_failure "Compilation Failed"
	finished=1
	printf 'Build failed (exit %s).\n' "$build_status" >&2
	exit "$build_status"
fi

duration=$(fmt_elapsed "$(($(date +%s) - start_time))")
zip_file=""
for file in Sashimi-*.zip; do
	[[ -s "$file" && -f "$file" ]] || continue
	fingerprint=$(stat -c '%i:%s:%y' -- "$file")
	[[ "${previous_zips[$file]:-}" != "$fingerprint" ]] || continue
	if [[ -z "$zip_file" || "$file" -nt "$zip_file" ]]; then
		zip_file="$file"
	fi
done
shopt -u nullglob

if [[ -z "$zip_file" ]]; then
	notify_failure "Compilation finished without a new ZIP"
	finished=1
	printf 'Error: build succeeded but no new or updated ZIP was found.\n' >&2
	exit 1
fi

ksu_status="No"
susfs_status="No"
case "$zip_file" in
	Sashimi-ksu-*) ksu_status="Yes" ;;
esac
case "$zip_file" in
	Sashimi-ksu-susfs-*) susfs_status="Yes" ;;
esac

caption="🍣 Sashimi Kernel (bangkk)
• Commit: ${commit_id}
• Message: ${commit_text}
• BakaSU: ${ksu_status}
• SusFS: ${susfs_status}
• Duration: ${duration} (<a href=\"${run_url_html}\">Workflow</a>)"

if [[ -n "$msg_id" ]]; then
	tg_post editMessageText --data-urlencode "message_id=$msg_id" \
		--data-urlencode "text=$(progress_text "$start_time")
• Uploading ZIP to Telegram..." > /dev/null || true
fi

upload_ok=0
if tg_request sendDocument --connect-timeout 15 --max-time 300 \
	--form-string "chat_id=$CHAT_ID" -F "document=@${zip_file}" \
	"${document_thread_args[@]}" --form-string "caption=$caption" \
	--form-string 'parse_mode=HTML' > /dev/null; then
	upload_ok=1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	if [[ "$upload_ok" == 1 ]]; then
		printf 'telegram_uploaded=true\n' >> "$GITHUB_OUTPUT"
	else
		printf 'telegram_uploaded=false\n' >> "$GITHUB_OUTPUT"
	fi
fi

if [[ "$upload_ok" != 1 ]]; then
	printf 'Error: build succeeded but Telegram upload failed.\n' >&2
	zip_html=$(html_escape "$zip_file")
	tg_post sendMessage "${thread_args[@]}" \
		--data-urlencode "text=Build succeeded (${zip_html}) but upload to Telegram failed. Check the <a href=\"${run_url_html}\">workflow</a> logs." > /dev/null || true
fi

if [[ -n "$msg_id" ]]; then
	tg_post deleteMessage --data-urlencode "message_id=$msg_id" > /dev/null || true
	if [[ -f "$message_file" && "$(< "$message_file")" == "$msg_id" ]]; then
		rm -f -- "$message_file" || true
	fi
fi

finished=1
[[ "$upload_ok" == 1 ]] || exit 1
exit 0
