#!/usr/bin/env bash
# Auto-resume installer for Claude Code
# Usage: bash install.sh [--upgrade|--uninstall|--check]

set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$INSTALLER_DIR/VERSION" 2>/dev/null || echo "unknown")
INSTALL_DIR="$HOME/.claude"
BIN_DIR="$INSTALL_DIR/bin"
HOOKS_DIR="$INSTALL_DIR/hooks"
SETTINGS="$INSTALL_DIR/settings.json"
VERSION_FILE="$INSTALL_DIR/auto-resume-version"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Prerequisites ──
check_prerequisites() {
    local ok=true

    if ! command -v jq >/dev/null 2>&1; then
        info "jq not found. Attempting to install..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y -qq jq >/dev/null 2>&1 && ok "jq installed via apt"
        elif command -v brew >/dev/null 2>&1; then
            brew install jq >/dev/null 2>&1 && ok "jq installed via brew"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y jq >/dev/null 2>&1 && ok "jq installed via yum"
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add jq >/dev/null 2>&1 && ok "jq installed via apk"
        fi
        if ! command -v jq >/dev/null 2>&1; then
            error "Failed to install jq automatically. Install manually: apt install jq / brew install jq"
            ok=false
        fi
    fi

    local bash_version
    bash_version="${BASH_VERSINFO[0]}"
    if [ "$bash_version" -lt 4 ]; then
        error "bash >= 4.0 required (found $BASH_VERSION)"
        ok=false
    fi

    if [ "$ok" = "false" ]; then
        exit 1
    fi
}

# ── Copy scripts ──
install_scripts() {
    mkdir -p "$BIN_DIR" "$HOOKS_DIR" "$INSTALL_DIR/logs"

    local scripts=(
        "claude-auto-resume.sh"
        "auto-resume-help.sh"
        "auto-resume-status.sh"
        "statusline-rate-cache-wrapper.sh"
    )

    for script in "${scripts[@]}"; do
        if [ -f "$INSTALLER_DIR/scripts/$script" ]; then
            cp "$INSTALLER_DIR/scripts/$script" "$BIN_DIR/$script"
            chmod +x "$BIN_DIR/$script"
        fi
    done

    local hooks=(
        "rate-limit-stop.sh"
        "rate-limit-stop-failure.sh"
        "rate-limit-prompt-guard.sh"
        "rate-limit-subagent-start.sh"
    )

    for hook in "${hooks[@]}"; do
        if [ -f "$INSTALLER_DIR/scripts/$hook" ]; then
            cp "$INSTALLER_DIR/scripts/$hook" "$HOOKS_DIR/$hook"
            chmod +x "$HOOKS_DIR/$hook"
        fi
    done

    ok "Scripts installed to $BIN_DIR and $HOOKS_DIR"
}

# ── Safe settings.json merge ──
merge_settings() {
    if [ ! -f "$SETTINGS" ]; then
        echo '{}' > "$SETTINGS"
    fi

    local tmp="$SETTINGS.tmp.$$"

    # Add hooks without overwriting existing ones
    local events=("Stop" "StopFailure" "UserPromptSubmit" "SubagentStart")
    local hook_scripts=("rate-limit-stop.sh" "rate-limit-stop-failure.sh" "rate-limit-prompt-guard.sh" "rate-limit-subagent-start.sh")

    local settings_data
    settings_data=$(cat "$SETTINGS")

    for i in "${!events[@]}"; do
        local event="${events[$i]}"
        local script="${hook_scripts[$i]}"
        local cmd="bash $HOOKS_DIR/$script"

        # Check if this hook is already registered
        if echo "$settings_data" | jq -e ".hooks.${event}" >/dev/null 2>&1; then
            if echo "$settings_data" | jq -r ".hooks.${event}[].hooks[].command // empty" 2>/dev/null | grep -q "$script"; then
                continue  # Already registered
            fi
        fi

        # Add the hook
        local hook_entry
        hook_entry=$(jq -n --arg cmd "$cmd" '[{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]')
        settings_data=$(echo "$settings_data" | jq --argjson entry "$hook_entry" ".hooks.${event} = (\$.hooks.${event} // []) + \$entry")
    done

    # Configure statusline wrapper if not already set
    if ! echo "$settings_data" | jq -r '.statusLine.command // ""' 2>/dev/null | grep -q "statusline-rate-cache-wrapper"; then
        local current_statusline
        current_statusline=$(echo "$settings_data" | jq -r '.statusLine.command // ""' 2>/dev/null)
        if [ -n "$current_statusline" ]; then
            # Save existing statusline as inner command
            echo "$current_statusline" > "$INSTALL_DIR/statusline-inner.conf"
        fi
        settings_data=$(echo "$settings_data" | jq --arg cmd "bash $BIN_DIR/statusline-rate-cache-wrapper.sh" '.statusLine.command = $cmd')
    fi

    echo "$settings_data" | jq '.' > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "Settings merged (hooks + statusline)"
}

# ── Write version ──
write_version() {
    echo "$VERSION" > "$VERSION_FILE"
    ok "Version $VERSION installed"
}

# ── Check installation ──
do_check() {
    info "Checking installation health..."
    local issues=0

    # Check scripts
    for script in claude-auto-resume.sh statusline-rate-cache-wrapper.sh; do
        if [ ! -x "$BIN_DIR/$script" ]; then
            error "Missing or non-executable: $BIN_DIR/$script"
            issues=$((issues + 1))
        fi
    done

    # Check hooks
    for hook in rate-limit-stop.sh rate-limit-stop-failure.sh rate-limit-prompt-guard.sh rate-limit-subagent-start.sh; do
        if [ ! -x "$HOOKS_DIR/$hook" ]; then
            error "Missing or non-executable: $HOOKS_DIR/$hook"
            issues=$((issues + 1))
        fi
    done

    # Check settings.json
    if [ -f "$SETTINGS" ]; then
        for event in Stop StopFailure UserPromptSubmit SubagentStart; do
            if ! jq -e ".hooks.$event" "$SETTINGS" >/dev/null 2>&1; then
                warn "Hook not registered for event: $event"
                issues=$((issues + 1))
            fi
        done

        if ! jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null | grep -q "statusline-rate-cache-wrapper"; then
            warn "Statusline wrapper not configured"
            issues=$((issues + 1))
        fi
    else
        error "settings.json not found"
        issues=$((issues + 1))
    fi

    # Check version
    if [ -f "$VERSION_FILE" ]; then
        local installed_version
        installed_version=$(cat "$VERSION_FILE")
        info "Installed version: $installed_version"
    else
        warn "Version file not found"
    fi

    # Check jq
    if ! command -v jq >/dev/null 2>&1; then
        error "jq not installed"
        issues=$((issues + 1))
    fi

    echo ""
    if [ "$issues" -eq 0 ]; then
        ok "Installation is healthy"
        return 0
    else
        error "$issues issue(s) found"
        return 1
    fi
}

# ── Upgrade ──
do_upgrade() {
    if [ -f "$VERSION_FILE" ]; then
        local installed_version
        installed_version=$(cat "$VERSION_FILE")
        if [ "$installed_version" = "$VERSION" ]; then
            ok "Already at version $VERSION — no upgrade needed"
            return 0
        fi
        info "Upgrading from $installed_version to $VERSION..."
    else
        info "No previous version found. Installing fresh..."
    fi
    install_scripts
    merge_settings
    write_version
    ok "Upgrade to $VERSION complete"
}

# ── Uninstall ──
do_uninstall() {
    info "Uninstalling auto-resume..."

    # Remove scripts
    for script in claude-auto-resume.sh auto-resume-help.sh auto-resume-status.sh statusline-rate-cache-wrapper.sh; do
        rm -f "$BIN_DIR/$script"
    done

    # Remove hooks
    for hook in rate-limit-stop.sh rate-limit-stop-failure.sh rate-limit-prompt-guard.sh rate-limit-subagent-start.sh; do
        rm -f "$HOOKS_DIR/$hook"
    done

    # Remove hooks from settings.json
    if [ -f "$SETTINGS" ]; then
        local tmp="$SETTINGS.tmp.$$"
        local settings_data
        settings_data=$(cat "$SETTINGS")

        for event in Stop StopFailure UserPromptSubmit SubagentStart; do
            # Remove hook entries that reference our scripts
            settings_data=$(echo "$settings_data" | jq "
                if .hooks.${event} then
                    .hooks.${event} |= [.[] | select(.hooks | all(.command | test(\"rate-limit\") | not))]
                    | if .hooks.${event} == [] then del(.hooks.${event}) else . end
                else . end
            ")
        done

        # Restore inner statusline if we have one saved
        if [ -f "$INSTALL_DIR/statusline-inner.conf" ]; then
            local inner_cmd
            inner_cmd=$(cat "$INSTALL_DIR/statusline-inner.conf")
            if [ -n "$inner_cmd" ]; then
                settings_data=$(echo "$settings_data" | jq --arg cmd "$inner_cmd" '.statusLine.command = $cmd')
            else
                settings_data=$(echo "$settings_data" | jq 'del(.statusLine.command)')
            fi
            rm -f "$INSTALL_DIR/statusline-inner.conf"
        else
            # Remove our statusline wrapper
            local current
            current=$(echo "$settings_data" | jq -r '.statusLine.command // ""')
            if echo "$current" | grep -q "statusline-rate-cache-wrapper"; then
                settings_data=$(echo "$settings_data" | jq 'del(.statusLine.command)')
            fi
        fi

        echo "$settings_data" | jq '.' > "$tmp" && mv "$tmp" "$SETTINGS"
    fi

    # Remove version file
    rm -f "$VERSION_FILE"
    rm -f "$INSTALL_DIR/rate-limits.json"

    ok "Auto-resume uninstalled"
}

# ── Main ──
case "${1:-}" in
    --check)
        do_check
        ;;
    --upgrade)
        check_prerequisites
        do_upgrade
        ;;
    --uninstall)
        do_uninstall
        ;;
    --help|-h)
        echo "Auto-resume installer v$VERSION"
        echo ""
        echo "Usage: bash install.sh [option]"
        echo ""
        echo "Options:"
        echo "  (none)        Fresh install"
        echo "  --upgrade     Upgrade to latest version"
        echo "  --uninstall   Remove auto-resume"
        echo "  --check       Verify installation health"
        echo "  --help        Show this help"
        ;;
    "")
        check_prerequisites
        info "Installing auto-resume v$VERSION..."
        install_scripts
        merge_settings
        write_version
        echo ""
        ok "Installation complete!"
        info "Run 'bash install.sh --check' to verify."
        ;;
    *)
        error "Unknown option: $1"
        echo "Run 'bash install.sh --help' for usage."
        exit 1
        ;;
esac
