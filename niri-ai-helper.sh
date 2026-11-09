#!/usr/bin/env bash
# =============================================================================
# niri-ai-helper.sh — Screenshot/selection OCR & translation for niri
#
# Subcommands (bound in binds.kdl):
#   ocr   — interactive region screenshot -> Baidu OCR -> floating popup
#   shot  — interactive region screenshot -> Agnes vision translation -> popup
#   sel   — current selection/clipboard text -> Agnes translation -> popup
#
# Hotkeys:  Ctrl+Alt+O = ocr | Ctrl+Alt+I = shot | Ctrl+Alt+T = sel
#
# Each result is also copied to the clipboard. The floating popup is rendered
# by niri-ai-popup.py (GTK3 layer-shell) and preserves source line breaks.
#
# Requirements: niri, curl, jq, base64, wl-copy, wl-paste, notify-send, python3.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/ai-secrets.env"

# Runtime temp dir: shared with the compositor so niri's screenshot --path write
# is visible to this process (do NOT use a bwrap-isolated /tmp).
TMPDIR_AI="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/niri-ai"
mkdir -p "$TMPDIR_AI" 2>/dev/null || TMPDIR_AI="/tmp"

# Load credentials
if [ -f "$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
fi

BAIDU_CLIENT_ID="${BAIDU_CLIENT_ID:-}"
BAIDU_CLIENT_SECRET="${BAIDU_CLIENT_SECRET:-}"
AGNES_API_KEY="${AGNES_API_KEY:-}"
AGNES_BASE_URL="${AGNES_BASE_URL:-https://api.agnes-ai.cn/v1}"
AGNES_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"
TARGET_LANG="${TARGET_LANG:-Chinese (Simplified)}"
TARGET_CODE="${TARGET_CODE:-zh-CN}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
notify() {
    local urgency="${1:-normal}" title="${2:-niri-ai}" body="${3:-}"
    notify-send -a "niri-ai" -u "$urgency" -t 6000 "$title" "$body" 2>/dev/null || true
}

die() {
    notify "critical" "niri-ai" "$1"
    echo "niri-ai: $1" >&2
    exit 1
}

# Take an interactive region screenshot (niri's own UI) and wait for the file.
#   $1 -> output path (absolute)
capture_region() {
    local out="$1" i
    rm -f "$out"

    # Open niri's interactive screenshot UI; it saves to $out on confirm.
    niri msg action screenshot --path "$out" >/dev/null 2>&1 || return 1

    # Poll up to 60s for the user to finish (Esc/cancel writes nothing).
    for i in $(seq 1 120); do
        [ -s "$out" ] && return 0
        sleep 0.5
    done
    return 1
}

# Get a Baidu access_token, caching it (valid ~30 days) to a JSON file.
baidu_token() {
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/niri-ai/baidu_token.json"
    local now token expiry
    now=$(date +%s)

    if [ -f "$cache" ]; then
        token=$(jq -r '.access_token // empty' "$cache" 2>/dev/null)
        expiry=$(jq -r '.expires_at // 0' "$cache" 2>/dev/null)
        if [ -n "$token" ] && [ "$now" -lt "$expiry" ]; then
            printf '%s' "$token"
            return 0
        fi
    fi

    local resp
    resp=$(curl -s -m 30 -X POST \
        "https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id=${BAIDU_CLIENT_ID}&client_secret=${BAIDU_CLIENT_SECRET}" \
        -H 'Content-Type: application/json') || return 1

    token=$(printf '%s' "$resp" | jq -r '.access_token // empty')
    if [ -z "$token" ]; then
        echo "Baidu token error: $(printf '%s' "$resp" | jq -r '.error_description // .error // "unknown"' 2>/dev/null)" >&2
        return 1
    fi

    # Cache best-effort: a read-only cache dir must not break OCR.
    mkdir -p "$(dirname "$cache")" 2>/dev/null || true
    printf '{"access_token":"%s","expires_at":%s}\n' "$token" "$((now + 2592000 - 3600))" > "$cache" 2>/dev/null \
        && chmod 600 "$cache" 2>/dev/null || true
    printf '%s' "$token"
}

# Baidu OCR accurate_basic on a PNG file; prints recognized text (newline-joined).
baidu_ocr() {
    local img="$1" b64 token resp
    b64=$(base64 -w0 "$img") || return 1
    token=$(baidu_token) || return 1

    resp=$(curl -s -m 60 -X POST \
        "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic?access_token=${token}" \
        --data-urlencode "image=$b64" \
        --data-urlencode 'detect_direction=false' \
        --data-urlencode 'paragraph=false' \
        --data-urlencode 'probability=false' \
        --data-urlencode 'multidirectional_recognize=false') || return 1

    if printf '%s' "$resp" | jq -e '.error_code' >/dev/null 2>&1; then
        echo "Baidu OCR error: $(printf '%s' "$resp" | jq -r '.error_msg' 2>/dev/null)" >&2
        return 1
    fi

    printf '%s' "$resp" | jq -r '.words_result[]?.words' 2>/dev/null
}

# Agnes chat completion; $1=JSON payload. Prints assistant content.
agnes_chat() {
    local payload="$1" resp
    resp=$(curl -s -m 120 -X POST "${AGNES_BASE_URL}/chat/completions" \
        -H "Authorization: Bearer ${AGNES_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "$payload") || return 1

    if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
        echo "Agnes error: $(printf '%s' "$resp" | jq -r '.error.message // .error' 2>/dev/null)" >&2
        return 1
    fi
    printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# Build the translator system prompt from the user template, asking the model
# to keep the source's line-break structure in the output.
translator_system() {
    cat <<EOF
You are a professional translator. Determine the source language of the text yourself, then translate it into ${TARGET_LANG} (${TARGET_CODE}), accurately conveying its meaning and nuances while adhering to ${TARGET_LANG} grammar, vocabulary, and cultural sensitivities.
Preserve the source text's line breaks and paragraph structure in the translation.
Produce only the ${TARGET_LANG} translation, without any additional explanations or commentary.
EOF
}

# Show the result in a floating popup (GTK layer-shell) and copy it to clipboard.
#   $1 title, $2 result, $3 source (optional), $4 source_label (optional)
show_popup() {
    local title="$1" result="$2" source="${3:-}" source_label="${4:-原文}"
    local json_file="${TMPDIR_AI}/popup-$$.json"

    if [ -z "$result" ]; then
        notify "normal" "$title" "Empty result."
        return 0
    fi

    python3 - "$json_file" "$title" "$source" "$source_label" "$result" <<'PYEOF'
import json, sys
path, title, source, source_label, result = sys.argv[1:6]
payload = {"title": title, "source": source, "source_label": source_label, "result": result}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
PYEOF

    # Copy translation to clipboard for convenience.
    printf '%s' "$result" | wl-copy 2>/dev/null || true

    # Launch the popup detached so it outlives this script.
    if [ -x "${SCRIPT_DIR}/niri-ai-popup.py" ]; then
        setsid python3 "${SCRIPT_DIR}/niri-ai-popup.py" "$json_file" >/dev/null 2>&1 &
        disown 2>/dev/null || true
    else
        rm -f "$json_file"
        notify "normal" "$title" "$(printf '%s' "$result" | head -c 300)"
    fi
}

# Copy text to clipboard (CLIPBOARD) and notify.
copy_and_notify() {
    local title="$1" text="$2" preview
    if [ -z "$text" ]; then
        notify "normal" "$title" "Empty result."
        return 0
    fi
    printf '%s' "$text" | wl-copy 2>/dev/null || true
    preview=$(printf '%s' "$text" | head -c 600 | tr '\n' ' ')
    notify "normal" "$title" "${preview:-copied to clipboard}"
}

# ----------------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------------
cmd_ocr() {
    local img="${TMPDIR_AI}/ocr-$$.png" text
    if ! capture_region "$img"; then
        notify "normal" "Baidu OCR" "Screenshot cancelled."
        return 0
    fi
    if ! text=$(baidu_ocr "$img"); then
        notify "critical" "Baidu OCR" "OCR failed. Check credentials/network."
        rm -f "$img"
        return 1
    fi
    rm -f "$img"
    show_popup "Baidu OCR 识别结果" "$text" "" "原文"
}

cmd_shot() {
    local img="${TMPDIR_AI}/shot-$$.png" b64 payload text
    if ! capture_region "$img"; then
        notify "normal" "Agnes Translate (screenshot)" "Screenshot cancelled."
        return 0
    fi
    b64=$(base64 -w0 "$img") || { rm -f "$img"; die "Failed to encode screenshot."; }
    rm -f "$img"

    payload=$(python3 - "$b64" <<'PYEOF'
import json, sys
b64 = sys.argv[1]
sys_prompt = '''You are a professional translator. Determine the source language of the text yourself, then translate it into {target_lang} ({target_code}), accurately conveying its meaning and nuances while adhering to {target_lang} grammar, vocabulary, and cultural sensitivities.
Preserve the source text's line breaks and paragraph structure in the translation.
Produce only the {target_lang} translation, without any additional explanations or commentary.'''.format(
    target_lang='Chinese (Simplified)', target_code='zh-CN')
msg = {
    'model': 'agnes-2.5-flash',
    'temperature': 0.3,
    'messages': [
        {'role': 'system', 'content': sys_prompt},
        {'role': 'user', 'content': [
            {'type': 'text', 'text': 'Read all visible text in this image, then translate it into {target_lang}. Preserve the line breaks and paragraph structure of the text in the image. Output only the {target_lang} translation, with no extra commentary.'.format(target_lang='Chinese (Simplified)')},
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + b64}}
        ]}
    ]
}
print(json.dumps(msg))
PYEOF
    ) || die "Failed to build payload."

    if ! text=$(agnes_chat "$payload"); then
        notify "critical" "Agnes Translate (screenshot)" "Translation failed. Check API key/network."
        return 1
    fi
    show_popup "Agnes 翻译（截图）" "$text" "" "原文"
}

cmd_sel() {
    local text payload source_text
    # Prefer PRIMARY (live selection), fall back to CLIPBOARD (explicit copy).
    source_text=$(wl-paste --primary 2>/dev/null)
    if [ -z "$source_text" ]; then
        source_text=$(wl-paste 2>/dev/null)
    fi
    if [ -z "$source_text" ]; then
        notify "normal" "Agnes Translate (selection)" "No text selected/copied."
        return 0
    fi

    payload=$(python3 - "$source_text" <<'PYEOF'
import json, sys
text = sys.argv[1]
sys_prompt = '''You are a professional translator. Determine the source language of the text yourself, then translate it into {target_lang} ({target_code}), accurately conveying its meaning and nuances while adhering to {target_lang} grammar, vocabulary, and cultural sensitivities.
Preserve the source text's line breaks and paragraph structure in the translation.
Produce only the {target_lang} translation, without any additional explanations or commentary.
Translate the following text into {target_lang}:
{text}'''.format(target_lang='Chinese (Simplified)', target_code='zh-CN', text=text)
print(json.dumps({
    'model': 'agnes-2.5-flash',
    'temperature': 0.3,
    'messages': [
        {'role': 'system', 'content': sys_prompt},
        {'role': 'user', 'content': 'Translate.'}
    ]
}))
PYEOF
    ) || die "Failed to build payload."

    if ! text=$(agnes_chat "$payload"); then
        notify "critical" "Agnes Translate (selection)" "Translation failed. Check API key/network."
        return 1
    fi
    show_popup "Agnes 翻译" "$text" "$source_text" "原文"
}

# ----------------------------------------------------------------------------
case "${1:-}" in
    ocr)  cmd_ocr ;;
    shot) cmd_shot ;;
    sel)  cmd_sel ;;
    *)
        echo "usage: $0 {ocr|shot|sel}" >&2
        exit 2
        ;;
esac
