#!/usr/bin/env bash
# =============================================================================
# niri-ai install script
#
# Installs the niri-ai OCR + translation helper into a (fresh) niri setup:
#   1. Copies niri-ai-helper.sh and niri-ai-popup.py to ~/.config/niri/scripts/
#   2. Creates ai-secrets.env (if missing) from an interactive prompt or the
#      bundled example file.
#   3. Adds the Ctrl+Alt+O / Ctrl+Alt+I / Ctrl+Alt+T keybindings to
#      ~/.config/niri/binds.kdl (idempotent: won't duplicate).
#   4. Validates and reloads the niri config.
#
# Usage:
#   ./install.sh                 # install, prompt for secrets if missing
#   ./install.sh --non-interactive   # never prompt; use example env file
#   ./install.sh --config DIR    # use a different niri config dir
#   ./install.sh --help
#
# Requirements: bash, niri, curl, jq, wl-clipboard, libnotify, python3,
#               python-gobject (gi), gtk3, gtk-layer-shell.
# =============================================================================
set -euo pipefail

# --- defaults ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/niri"
SECRETS_FILE="$CONFIG_DIR/scripts/ai-secrets.env"
BINDS_FILE="$CONFIG_DIR/binds.kdl"
NON_INTERACTIVE=0
RELOAD=1

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=1 ;;
        --config)
            [ $# -ge 2 ] || die "--config requires a directory"
            CONFIG_DIR="$2"; shift
            SECRETS_FILE="$CONFIG_DIR/scripts/ai-secrets.env"
            BINDS_FILE="$CONFIG_DIR/binds.kdl"
            ;;
        --no-reload) RELOAD=0 ;;
        --help|-h) usage 0 ;;
        *) usage 1 ;;
    esac
    shift
done

# --- dependency checks ------------------------------------------------------
check_deps() {
    log "Checking dependencies..."
    local missing=0
    for cmd in niri curl jq base64 wl-copy wl-paste notify-send python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd"
        else
            warn "MISSING: $cmd"; missing=1
        fi
    done

    # Python GTK3 + GtkLayerShell import check.
    if python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("GtkLayerShell","0.1"); from gi.repository import Gtk, GtkLayerShell' 2>/dev/null; then
        ok "python3 + GTK3 + GtkLayerShell"
    else
        warn "python3 cannot import GTK3/GtkLayerShell (need: python-gobject, gtk3, gtk-layer-shell)"
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        warn "Install missing packages. On Arch/CachyOS:"
        warn "  sudo pacman -S niri curl jq wl-clipboard libnotify python python-gobject gtk3 gtk-layer-shell"
        die "Missing dependencies (see above)."
    fi
}

# --- secrets ----------------------------------------------------------------
ask() { # $1 prompt, returns value via REPLY
    local prompt="$1"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf '%s\n' ""
        return 0
    fi
    read -r -p "$prompt" REPLY || true
}

create_secrets() {
    if [ -f "$SECRETS_FILE" ]; then
        log "Secrets already present: $SECRETS_FILE (leaving unchanged)"
        return 0
    fi
    mkdir -p "$(dirname "$SECRETS_FILE")"

    local example="$SCRIPT_DIR/ai-secrets.env.example"
    if [ -f "$example" ] && [ "$NON_INTERACTIVE" -eq 1 ]; then
        cp "$example" "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
        log "Copied example secrets to $SECRETS_FILE"
        warn "EDIT $SECRETS_FILE and fill in your real API credentials."
        return 0
    fi

    log "No ai-secrets.env found — please provide your API credentials."
    echo
    local bcid bcsec akey
    ask "Baidu OCR Client ID: "; bcid="$REPLY"
    ask "Baidu OCR Client Secret: "; bcsec="$REPLY"
    ask "Agnes API Key: "; akey="$REPLY"

    cat > "$SECRETS_FILE" <<EOF
# Baidu OCR credentials (https://cloud.baidu.com/product/ocr)
BAIDU_CLIENT_ID="${bcid:-YOUR_BAIDU_CLIENT_ID}"
BAIDU_CLIENT_SECRET="${bcsec:-YOUR_BAIDU_CLIENT_SECRET}"

# Agnes LLM (OpenAI-compatible)
AGNES_API_KEY="${akey:-YOUR_AGNES_API_KEY}"
AGNES_BASE_URL="https://api.agnes-ai.cn/v1"
AGNES_MODEL="agnes-2.5-flash"

# Target translation language
TARGET_LANG="Chinese (Simplified)"
TARGET_CODE="zh-CN"
EOF
    chmod 600 "$SECRETS_FILE"
    ok "Created $SECRETS_FILE (chmod 600)"
}

# --- copy scripts -----------------------------------------------------------
install_scripts() {
    local dest="$CONFIG_DIR/scripts"
    mkdir -p "$dest"
    log "Installing scripts to $dest"
    cp "$SCRIPT_DIR/niri-ai-helper.sh" "$dest/niri-ai-helper.sh"
    cp "$SCRIPT_DIR/niri-ai-popup.py"  "$dest/niri-ai-popup.py"
    chmod 755 "$dest/niri-ai-helper.sh" "$dest/niri-ai-popup.py"
    ok "Installed niri-ai-helper.sh, niri-ai-popup.py"
}

# --- keybindings (idempotent) ------------------------------------------------
# Paths use the configured scripts dir; `~` is expanded by niri's spawn.
SCRIPT_PATH="$CONFIG_DIR/scripts/niri-ai-helper.sh"
SCRIPT_PATH_KDL="${SCRIPT_PATH/#$HOME/\~}"

BIND_BLOCK=$(cat <<EOF
    // 区域截图 -> 百度 OCR (浮窗+剪贴板) / Region screenshot -> Baidu OCR (popup+clipboard)
    Ctrl+Alt+O repeat=false cooldown-ms=500 hotkey-overlay-title="Baidu OCR screenshot" { spawn "$SCRIPT_PATH_KDL" "ocr"; }

    // 区域截图 -> Agnes 视觉翻译 (浮窗+剪贴板) / Region screenshot -> Agnes vision translate (popup+clipboard)
    Ctrl+Alt+I repeat=false cooldown-ms=500 hotkey-overlay-title="Agnes translate screenshot" { spawn "$SCRIPT_PATH_KDL" "shot"; }

    // 当前选中/复制的文字 -> Agnes 翻译 (浮窗+剪贴板) / Selection/clipboard -> Agnes translate (popup+clipboard)
    Ctrl+Alt+T repeat=false cooldown-ms=500 hotkey-overlay-title="Agnes translate selection" { spawn "$SCRIPT_PATH_KDL" "sel"; }
EOF
)

patch_binds() {
    if [ ! -f "$BINDS_FILE" ]; then
        warn "No binds.kdl found at $BINDS_FILE — creating one."
        mkdir -p "$(dirname "$BINDS_FILE")"
        {
            echo "// niri-ai keybindings (created by niri-ai install)"
            echo "binds {"
            printf '%s\n' "$BIND_BLOCK"
            echo "}"
        } > "$BINDS_FILE"
        ok "Created $BINDS_FILE"
        return 0
    fi

    # Idempotent: skip if already present.
    if grep -q 'niri-ai-helper.sh' "$BINDS_FILE"; then
        log "Keybindings already present in $BINDS_FILE (leaving unchanged)"
        return 0
    fi

    # Insert before the LAST line that is exactly `}` (closes the binds block).
    log "Adding keybindings to $BINDS_FILE"
    local lineno
    lineno=$(grep -n '^}' "$BINDS_FILE" | tail -1 | cut -d: -f1)
    if [ -n "$lineno" ]; then
        {
            sed -n "1,$((lineno-1))p" "$BINDS_FILE"
            printf '%s\n' "$BIND_BLOCK"
            sed -n "${lineno},\$p" "$BINDS_FILE"
        } > "$BINDS_FILE.tmp"
        mv "$BINDS_FILE.tmp" "$BINDS_FILE"
        ok "Inserted keybindings before line $lineno"
    else
        warn "No closing brace found in $BINDS_FILE; appending a binds block."
        {
            cat "$BINDS_FILE"
            echo "binds {"
            printf '%s\n' "$BIND_BLOCK"
            echo "}"
        } > "$BINDS_FILE.tmp"
        mv "$BINDS_FILE.tmp" "$BINDS_FILE"
        ok "Appended binds block"
    fi
}

# --- reload -----------------------------------------------------------------
reload_config() {
    [ "$RELOAD" -eq 1 ] || return 0
    log "Reloading niri config..."
    if niri validate 2>/dev/null; then
        ok "Config validates"
    else
        warn "niri validate reported issues — review binds.kdl before using the hotkeys."
    fi
    if niri msg action load-config-file >/dev/null 2>&1; then
        ok "Config reloaded"
    else
        warn "Could not reload config (is niri running?). Hotkeys apply on next login."
    fi
}

# --- main -------------------------------------------------------------------
main() {
    echo
    log "niri-ai installer"
    log "  config dir : $CONFIG_DIR"
    log "  secrets    : $SECRETS_FILE"
    log "  binds      : $BINDS_FILE"
    echo
    check_deps
    install_scripts
    create_secrets
    patch_binds
    reload_config
    echo
    ok "Install complete."
    echo
    cat <<'EOF'
  Hotkeys (after reload):
    Ctrl+Alt+O  region screenshot -> Baidu OCR          -> floating popup + clipboard
    Ctrl+Alt+I  region screenshot -> Agnes translation  -> floating popup + clipboard
    Ctrl+Alt+T  selection/clipboard -> Agnes translation -> floating popup + clipboard

  If your secrets were just created, edit them first:
    ~/.config/niri/scripts/ai-secrets.env
EOF
    echo
}

main "$@"
