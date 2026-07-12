#!/usr/bin/env bash
# =============================================================================
# Ubuntu Bootstrap Script (WSL & Server)
# Idempotent setup driven by an upfront selection menu: pick your steps and
# answer every prompt first, then the script runs unattended.
# Steps: zsh, Starship, plugins (pinned), pyenv (optional), SSH, git, dotfiles
# =============================================================================
set -euo pipefail

# ── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"
BACKUP_DIR="${HOME}/.dotfiles.bak"
SSH_KEY="${HOME}/.ssh/id_ed25519"

info()    { printf "${CYAN}[→]${NC}  %s\n" "$1"; }
success() { printf "${GREEN}[✓]${NC}  %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC}  %s\n" "$1"; }
error()   { printf "${RED}[✗]${NC}  %s\n" "$1"; }
section() {
    local title="$1"
    local pad_len=$(( 44 - ${#title} ))
    (( pad_len < 2 )) && pad_len=2
    local pad
    pad=$(printf '─%.0s' $(seq 1 "$pad_len"))
    printf "\n${BOLD}${BLUE}── %s %s${NC}\n" "$title" "$pad"
}
header()  {
    printf "\n${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}\n"
    printf "${BOLD}${BLUE}║  %-44s║${NC}\n" "$1"
    printf "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}\n\n"
}
# Only clear when attached to a terminal, so piped output stays clean
clear_screen() { if [[ -t 1 ]]; then printf '\033[H\033[2J'; fi; }
print_banner() {
    clear_screen
    header "Ubuntu Bootstrap"
    if $IS_WSL; then
        info "Environment: WSL"
    else
        info "Environment: native Linux"
    fi
}

# ── Input Validation ─────────────────────────────────────────────────────────
NAME_RE="^[[:alnum:]][[:alnum:] .'-]{0,63}$"
EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

valid_name()  { [[ "$1" =~ $NAME_RE ]]; }
valid_email() { [[ "$1" =~ $EMAIL_RE ]]; }

# Prompts until the validator accepts the input; result lands in INPUT_VALUE.
# Pass allow_blank=1 to let an empty answer mean "skip".
read_validated() {
    local prompt="$1" validator="$2" hint="$3" allow_blank="${4:-0}"
    INPUT_VALUE=""
    while true; do
        read -rp "  ${prompt}: " INPUT_VALUE
        if [[ -z "$INPUT_VALUE" ]]; then
            if (( allow_blank )); then return 0; fi
            warn "A value is required. ${hint}"
            continue
        fi
        if "$validator" "$INPUT_VALUE"; then return 0; fi
        warn "Invalid value. ${hint}"
    done
}

# ── Sudo Detection ──────────────────────────────────────────────────────────
if [[ "$EUID" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ── Step Functions ──────────────────────────────────────────────────────────

step_system_update() {
    info "Updating package lists..."
    $SUDO apt-get update -qq
    info "Upgrading installed packages..."
    $SUDO apt-get upgrade -y -qq
    success "System updated"
}

step_core_packages() {
    CORE_PACKAGES=(vim git curl tmux unzip dnsutils wget build-essential)
    local missing=()

    for pkg in "${CORE_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        $SUDO apt-get install -y -qq "${missing[@]}"
        success "Core packages installed"
    else
        success "All core packages already installed"
    fi
}

step_zsh() {
    if command -v zsh &>/dev/null; then
        success "zsh already installed ($(zsh --version))"
    else
        info "Installing zsh..."
        $SUDO apt-get install -y -qq zsh
        success "zsh installed"
    fi
}

step_starship() {
    if command -v starship &>/dev/null; then
        success "Starship already installed ($(starship --version | head -1))"
        return 0
    fi
    # Download to a temp file instead of piping curl straight into sh, so the
    # installer can be inspected (and the download can fail cleanly) first.
    local installer
    installer="$(mktemp /tmp/starship-install.XXXXXX.sh)"
    info "Downloading Starship installer to ${installer}..."
    curl -fsSL https://starship.rs/install.sh -o "$installer"
    info "Running Starship installer..."
    sh "$installer" --yes
    rm -f "$installer"
    success "Starship installed"
}

step_plugins() {
    ZSH_PLUGIN_DIR="${HOME}/.zsh"
    mkdir -p "$ZSH_PLUGIN_DIR"

    declare -A PLUGINS=(
        [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions.git"
        [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
    )
    # Pinned to release tags so re-runs can't pull unreviewed upstream changes.
    # Bump deliberately after reviewing the upstream diff.
    declare -A PLUGIN_PIN=(
        [zsh-autosuggestions]="v0.7.1"
        [zsh-syntax-highlighting]="0.8.0"
    )

    local plugin plugin_path pin current
    for plugin in "${!PLUGINS[@]}"; do
        plugin_path="${ZSH_PLUGIN_DIR}/${plugin}"
        pin="${PLUGIN_PIN[$plugin]}"
        if [[ -d "$plugin_path" ]]; then
            current="$(git -C "$plugin_path" describe --tags --exact-match 2>/dev/null || true)"
            if [[ "$current" == "$pin" ]]; then
                success "${plugin} already at ${pin}"
            elif git -C "$plugin_path" fetch -q --depth=1 origin tag "$pin" 2>/dev/null; then
                git -C "$plugin_path" -c advice.detachedHead=false checkout -q "$pin"
                success "${plugin} pinned to ${pin}"
            else
                warn "Could not update ${plugin} to ${pin} (offline?)"
            fi
        else
            info "Cloning ${plugin} @ ${pin}..."
            git clone -q --depth=1 --branch "$pin" -c advice.detachedHead=false "${PLUGINS[$plugin]}" "$plugin_path"
            success "${plugin} installed @ ${pin}"
        fi
    done
}

step_pyenv() {
    if command -v pyenv &>/dev/null; then
        success "pyenv already installed ($(pyenv --version))"
        return 0
    fi

    # pyenv build dependencies
    PYENV_DEPS=(
        libssl-dev libbz2-dev libreadline-dev libsqlite3-dev
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev
        libffi-dev liblzma-dev
    )
    info "Installing pyenv build dependencies..."
    $SUDO apt-get install -y -qq "${PYENV_DEPS[@]}"

    # Same download-then-execute pattern as the Starship installer.
    local installer
    installer="$(mktemp /tmp/pyenv-install.XXXXXX.sh)"
    info "Downloading pyenv installer to ${installer}..."
    curl -fsSL https://pyenv.run -o "$installer"
    info "Running pyenv installer..."
    bash "$installer"
    rm -f "$installer"

    # Make pyenv available for the rest of this script
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"

    success "pyenv installed ($(pyenv --version))"
}

# Announce every setting as it's applied: current value shown when overwriting.
# set_git_config <key> <value> <description>
set_git_config() {
    local key="$1" value="$2" desc="$3" current
    current="$(git config --global --get "$key" 2>/dev/null || true)"
    if [[ "$current" == "$value" ]]; then
        success "${desc}: ${value} (already set)"
    else
        git config --global "$key" "$value"
        if [[ -n "$current" ]]; then
            success "${desc}: ${value} (was: ${current})"
        else
            success "${desc}: ${value}"
        fi
    fi
}

step_git_config() {
    if [[ -n "$GIT_NAME" ]]; then
        # Defense in depth: input was validated at the prompt, re-check before use
        valid_name "$GIT_NAME" || { error "Invalid git user.name — refusing to pass to git config."; exit 1; }
        git config --global user.name "$GIT_NAME"
        success "Git user.name set to: $GIT_NAME"
    elif [[ -n "$GIT_NAME_CURRENT" ]]; then
        success "Git user.name already set: $GIT_NAME_CURRENT"
    else
        warn "Skipped user.name — no name entered"
    fi

    if [[ -n "$GIT_EMAIL" ]]; then
        valid_email "$GIT_EMAIL" || { error "Invalid git user.email — refusing to pass to git config."; exit 1; }
        git config --global user.email "$GIT_EMAIL"
        success "Git user.email set to: $GIT_EMAIL"
    elif [[ -n "$GIT_EMAIL_CURRENT" ]]; then
        success "Git user.email already set: $GIT_EMAIL_CURRENT"
    else
        warn "Skipped user.email — no email entered"
    fi

    set_git_config init.defaultBranch main "Default branch for new repos"
    set_git_config core.editor vim "Default editor"
    set_git_config alias.st status "Alias 'git st'"
    set_git_config alias.co checkout "Alias 'git co'"
    set_git_config alias.br branch "Alias 'git br'"
    set_git_config alias.lg "log --oneline --graph --decorate --all" "Alias 'git lg'"
}

step_ssh_key() {
    if [[ -f "$SSH_KEY" ]]; then
        success "SSH key already exists: ${SSH_KEY}"
        return 0
    fi
    if [[ -z "$SSH_EMAIL" ]]; then
        warn "Skipped — no email entered"
        return 0
    fi
    valid_email "$SSH_EMAIL" || { error "Invalid SSH email — refusing to pass to ssh-keygen."; exit 1; }

    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f "$SSH_KEY" -N "$SSH_PASSPHRASE"
    success "SSH key generated: ${SSH_KEY}"
    info "Public key:"
    cat "${SSH_KEY}.pub"
}

step_dotfiles() {
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        warn "Dotfiles directory not found: ${DOTFILES_DIR}"
        warn "Skipping dotfile symlinks"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    DOTFILES=(.zshrc .tmux.conf .vimrc)

    local dotfile src dest
    for dotfile in "${DOTFILES[@]}"; do
        src="${DOTFILES_DIR}/${dotfile}"
        dest="${HOME}/${dotfile}"

        if [[ ! -f "$src" ]]; then
            warn "Source not found, skipping: ${src}"
            continue
        fi

        # Already correctly linked
        if [[ -L "$dest" ]] && [[ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]]; then
            success "${dotfile} already linked"
            continue
        fi

        # Backup existing file
        if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
            info "Backing up existing ${dotfile} → ${BACKUP_DIR}/"
            mv "$dest" "${BACKUP_DIR}/${dotfile}.$(date +%Y%m%d%H%M%S)"
        fi

        ln -s "$src" "$dest"
        success "${dotfile} → linked"
    done

    # Starship config symlink (XDG location)
    local starship_src="${DOTFILES_DIR}/starship.toml"
    local starship_dest="${HOME}/.config/starship.toml"
    mkdir -p "${HOME}/.config"
    if [[ -L "$starship_dest" ]] && [[ "$(readlink -f "$starship_dest")" = "$(readlink -f "$starship_src")" ]]; then
        success "starship.toml already linked"
    else
        if [[ -e "$starship_dest" ]] || [[ -L "$starship_dest" ]]; then
            info "Backing up existing starship.toml → ${BACKUP_DIR}/"
            mv "$starship_dest" "${BACKUP_DIR}/starship.toml.$(date +%Y%m%d%H%M%S)"
        fi
        ln -s "$starship_src" "$starship_dest"
        success "starship.toml → linked"
    fi
}

step_default_shell() {
    local zsh_path current_shell
    zsh_path="$(which zsh)"
    current_shell="$(getent passwd "$(whoami)" | cut -d: -f7)"

    if [[ "$current_shell" = "$zsh_path" ]]; then
        success "Default shell is already zsh"
    else
        info "Changing default shell to zsh..."
        chsh -s "$zsh_path"
        success "Default shell set to zsh"
    fi
}

# ── Step Registry ───────────────────────────────────────────────────────────
STEP_KEYS=(update core zsh starship plugins pyenv gitcfg ssh dotfiles shell)
declare -A STEP_LABEL=(
    [update]="System update (apt update/upgrade)"
    [core]="Core packages"
    [zsh]="Zsh"
    [starship]="Starship prompt"
    [plugins]="Zsh plugins (pinned)"
    [pyenv]="Python (pyenv)"
    [gitcfg]="Git configuration"
    [ssh]="SSH key (ed25519)"
    [dotfiles]="Dotfiles"
    [shell]="Default shell → zsh"
)
declare -A STEP_MANDATORY=(
    [update]=1 [core]=1 [zsh]=1 [starship]=1 [plugins]=1
    [pyenv]=0 [gitcfg]=1 [ssh]=0 [dotfiles]=1 [shell]=1
)
# Initial menu state for optional steps (1 = pre-checked)
declare -A STEP_DEFAULT=([pyenv]=0 [ssh]=1)
declare -A STEP_FUNC=(
    [update]=step_system_update
    [core]=step_core_packages
    [zsh]=step_zsh
    [starship]=step_starship
    [plugins]=step_plugins
    [pyenv]=step_pyenv
    [gitcfg]=step_git_config
    [ssh]=step_ssh_key
    [dotfiles]=step_dotfiles
    [shell]=step_default_shell
)
declare -A SELECTED=()

# ── Selection Menu ──────────────────────────────────────────────────────────
select_menu() {
    local optional=() k i tok reply mark notice=""
    for k in "${STEP_KEYS[@]}"; do
        if [[ "${STEP_MANDATORY[$k]}" != "1" ]]; then
            optional+=("$k")
            SELECTED[$k]="${STEP_DEFAULT[$k]:-0}"
        fi
    done

    while true; do
        # Redraw in place: clear + banner each pass so toggles update the
        # checkboxes instead of stacking a new copy of the menu
        print_banner
        section "Setup Selection"
        printf "\n  ${BOLD}Always runs:${NC}\n"
        for k in "${STEP_KEYS[@]}"; do
            if [[ "${STEP_MANDATORY[$k]}" == "1" ]]; then
                printf "      • %s\n" "${STEP_LABEL[$k]}"
            fi
        done
        printf "\n  ${BOLD}Optional (toggle by number):${NC}\n"
        i=1
        for k in "${optional[@]}"; do
            mark="[ ]"
            if [[ "${SELECTED[$k]}" == "1" ]]; then mark="[x]"; fi
            printf "  %2d) %s %s\n" "$i" "$mark" "${STEP_LABEL[$k]}"
            (( i++ )) || true
        done
        printf "\n"
        if [[ -n "$notice" ]]; then
            warn "Ignored: $notice"
            notice=""
        fi
        read -rp "  Numbers to toggle (space-separated), 'a'=all, 'n'=none, Enter/'d'=done: " reply

        case "$reply" in
            ""|d|D) return 0 ;;
            a|A) for k in "${optional[@]}"; do SELECTED[$k]=1; done ;;
            n|N) for k in "${optional[@]}"; do SELECTED[$k]=0; done ;;
            *)
                for tok in $reply; do
                    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#optional[@]} )); then
                        k="${optional[$((tok - 1))]}"
                        if [[ "${SELECTED[$k]}" == "1" ]]; then SELECTED[$k]=0; else SELECTED[$k]=1; fi
                    else
                        # Buffered and shown after the redraw, so the clear doesn't eat it
                        notice="${notice:+${notice}, }${tok}"
                    fi
                done ;;
        esac
    done
}

# ── Upfront Input (validated here, before anything runs) ───────────────────
collect_input() {
    GIT_NAME=""
    GIT_EMAIL=""
    GIT_NAME_CURRENT=""
    GIT_EMAIL_CURRENT=""
    SSH_EMAIL=""
    SSH_PASSPHRASE=""

    if command -v git &>/dev/null; then
        GIT_NAME_CURRENT="$(git config --global user.name 2>/dev/null || true)"
        GIT_EMAIL_CURRENT="$(git config --global user.email 2>/dev/null || true)"
    fi

    if [[ -n "$GIT_NAME_CURRENT" ]]; then
        success "Git user.name already set: $GIT_NAME_CURRENT"
    else
        read_validated "Git user.name (e.g. Your Name; blank to skip)" valid_name \
            "Letters, numbers, spaces, . ' - only (max 64 chars)." 1
        GIT_NAME="$INPUT_VALUE"
    fi

    if [[ -n "$GIT_EMAIL_CURRENT" ]]; then
        success "Git user.email already set: $GIT_EMAIL_CURRENT"
    else
        read_validated "Git user.email (e.g. you@example.com; blank to skip)" valid_email \
            "Expected form: user@example.com" 1
        GIT_EMAIL="$INPUT_VALUE"
    fi

    if [[ "${SELECTED[ssh]:-0}" == "1" ]] && [[ ! -f "$SSH_KEY" ]]; then
        read_validated "Email for SSH key (blank to skip)" valid_email \
            "Expected form: user@example.com" 1
        SSH_EMAIL="$INPUT_VALUE"
        if [[ -n "$SSH_EMAIL" ]]; then
            read -rsp "  SSH key passphrase (blank for none): " SSH_PASSPHRASE
            printf "\n"
            if [[ -z "$SSH_PASSPHRASE" ]]; then
                warn "No passphrase — the private key will be stored unencrypted on disk."
            fi
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
else
    IS_WSL=false
fi

print_banner

select_menu

section "Configuration Input"
collect_input

# Fresh screen for the unattended run; the step log scrolls from here
print_banner

for k in "${STEP_KEYS[@]}"; do
    if [[ "${STEP_MANDATORY[$k]}" == "1" ]] || [[ "${SELECTED[$k]:-0}" == "1" ]]; then
        section "${STEP_LABEL[$k]}"
        "${STEP_FUNC[$k]}"
    fi
done

# ── Summary ─────────────────────────────────────────────────────────────────
section "Setup Complete"
echo ""
printf "${GREEN}${BOLD}  ✓ Core packages installed${NC}\n"
printf "${GREEN}${BOLD}  ✓ Zsh + Starship prompt${NC}\n"
printf "${GREEN}${BOLD}  ✓ Plugins: autosuggestions, syntax-highlighting (pinned)${NC}\n"
if command -v pyenv &>/dev/null; then
    printf "${GREEN}${BOLD}  ✓ pyenv installed${NC}\n"
fi
if [[ -f "$SSH_KEY" ]]; then
    printf "${GREEN}${BOLD}  ✓ SSH key configured${NC}\n"
fi
printf "${GREEN}${BOLD}  ✓ Git configured${NC}\n"
printf "${GREEN}${BOLD}  ✓ Dotfiles symlinked${NC}\n"
printf "${GREEN}${BOLD}  ✓ Default shell: zsh${NC}\n"
echo ""

if $IS_WSL; then
    warn "WSL Detected — Run setup-windows.ps1 on the Windows side to install the JetBrains Mono Nerd Font and configure PowerShell."
fi

info "Open a new terminal session (or run 'zsh') to start using your new shell"
