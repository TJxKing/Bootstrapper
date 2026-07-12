# Cross-Platform Bootstrap (Linux/WSL + Windows Terminal)

Idempotent bootstrap scripts for a modern terminal setup on both Ubuntu/WSL and Windows Terminal. One shared `starship.toml` drives the prompt on both sides.

Both scripts open with a selection menu: mandatory steps are listed, optional steps toggle by number, and all input (git identity, SSH email/passphrase) is collected and validated up front — after that the run is unattended. Every setting the scripts change is announced line-by-line as it's applied — no silent config edits.

## Quick Start

### Windows

One block, fresh machine OK. Open any PowerShell window (Start → search "PowerShell") and paste:

```powershell
# Install Git and PowerShell 7 (winget skips anything already installed)
winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements
# Make git available in this window without restarting it
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
# Get the repo and run setup (the script relaunches itself in PowerShell 7)
git clone https://github.com/TJxKing/Bootstrapper "$HOME\bootstrap"
cd "$HOME\bootstrap"
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

> `-ExecutionPolicy Bypass` on the command line applies **to that process only** — it does not relax the machine-wide or user execution policy. Avoid `Set-ExecutionPolicy Bypass`, which would change policy persistently.

### Linux / WSL

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/TJxKing/Bootstrapper ~/bootstrap
cd ~/bootstrap
bash setup-linux.sh
```

**WSL users:** run the Linux block inside WSL, then the Windows block in Windows — the Nerd Font and terminal settings live on the Windows side.

After either setup completes, **open a new terminal** to activate the new shell/prompt.

## What Gets Installed

### Linux / WSL (`setup-linux.sh`)

| Component | Details |
|---|---|
| **Core packages** | `vim` `git` `curl` `tmux` `unzip` `dnsutils` `wget` `build-essential` |
| **Zsh** | Default shell |
| **Starship** | Cross-platform prompt; installer downloaded to a temp file, then executed |
| **Zsh plugins** | `zsh-autosuggestions`, `zsh-syntax-highlighting` in `~/.zsh/`, pinned to release tags |
| **pyenv** | *Optional* — toggle in the setup menu |
| **Git config** | Prompted for `user.name` and `user.email` (validated); sets `init.defaultBranch=main`, `core.editor=vim`, and aliases `st`/`co`/`br`/`lg` — each change announced, previous value shown |
| **SSH key** | *Optional (default on)* — ed25519 key with optional passphrase, generated if one doesn't exist |
| **Dotfiles** | `.zshrc`, `.tmux.conf`, `.vimrc` symlinked to `$HOME`; `starship.toml` symlinked to `~/.config/` |

### Windows (`setup-windows.ps1`)

| Component | Details |
|---|---|
| **PowerShell 7** | Installed via `winget` if not present; script self-relaunches in PS7 automatically |
| **Git** | Installed via `winget` if not present |
| **JetBrains Mono Nerd Font** | *Optional (default on)* — pinned release download, SHA256-verified, installed per-user (no admin required) |
| **Starship** | Installed via `winget` |
| **Starship config** | `dotfiles\starship.toml` copied to `%USERPROFILE%\.config\starship.toml` |
| **PSReadLine 2.2+** | ListView prediction, vim-friendly key bindings |
| **PowerShell profile** | Managed sentinel block added to `$PROFILE` |
| **Git config** | Prompted for `user.name` and `user.email` (validated); sets `init.defaultBranch=main`, `core.autocrlf=true`, `credential.helper=manager`, `core.editor=vim`, and aliases `st`/`co`/`br`/`lg` — each change announced, previous value shown |
| **SSH key** | *Optional (default on)* — ed25519 key with optional passphrase, generated if one doesn't exist |
| **Optional apps** | VS Code, Claude desktop, Obsidian, AutoHotkey, 7-Zip, Flameshot — toggle in the setup menu; installed via `winget` user-scope where the package supports it (7-Zip and Flameshot fall back to machine-wide) |

## Re-running

Both scripts are idempotent — safe to run again at any time. They skip steps that are already complete and never overwrite user content outside their managed blocks. Already cloned? Update and re-run:

```bash
cd ~/bootstrap && git pull
```

## Security Notes

- **No hidden changes** — every git setting, font registration, and profile edit is announced as it's applied, including the previous value when one is overwritten.
- **Pinned font download** — the Nerd Font zip is downloaded from a pinned release (not `latest`) and its SHA256 is verified before extraction; a mismatch aborts the run.
- **winget source verification** — the Windows script confirms the `winget` source resolves to the official Microsoft CDN before installing anything, and passes `--source winget` on every install (never `msstore`).
- **Pinned zsh plugins** — plugins are cloned at release tags, not tracked branches, so re-runs can't pull unreviewed upstream changes. Bump the pins in `setup-linux.sh` deliberately.
- **No `curl | sh`** — the Starship and pyenv installers are downloaded to a temp file, then executed, so the download can be inspected and fails cleanly.
- **Validated input** — git name/email and the SSH email are regex-validated at the prompt and re-checked before being passed to `git config` / `ssh-keygen`.
- **SSH passphrase** — you're prompted for an optional key passphrase; leaving it blank prints a warning that the private key is stored unencrypted.
- **Process-scoped execution policy** — the documented invocation bypasses execution policy for that process only.

## Customizing

### Starship prompt

Edit `dotfiles/starship.toml` and re-run your platform's setup script (Linux re-symlinks; Windows re-copies with backup if changed). Full config reference at [starship.rs/config](https://starship.rs/config/).

### Dotfiles

Edit files in `dotfiles/` and re-run `./setup-linux.sh` — existing symlinks update automatically.

### Adding packages (Linux)

Append to the `CORE_PACKAGES` array in `step_core_packages` in `setup-linux.sh`.

### Adding optional apps (Windows)

Add an entry to the `$Steps` array in `setup-windows.ps1` with `Mandatory = $false` and an `Install-WingetApp '<winget id>' '<name>'` action — it appears in the menu automatically.

## File Structure

```
.
├── setup-linux.sh        # Linux/WSL bootstrap
├── setup-windows.ps1     # Windows Terminal bootstrap (PS7)
├── README.md
└── dotfiles/
    ├── .zshrc            # Zsh config (Starship + plugins + aliases)
    ├── .tmux.conf        # Tmux sane defaults
    ├── .vimrc            # Vim sane defaults
    └── starship.toml     # Shared Starship prompt config
```

## Tmux Cheat Sheet

The config rebinds the prefix to `Ctrl+a` (instead of `Ctrl+b`):

| Action | Keys |
|---|---|
| Split horizontal | `Ctrl+a` then `\|` |
| Split vertical | `Ctrl+a` then `-` |
| Navigate panes | `Ctrl+a` then `h/j/k/l` |
| Resize panes | `Ctrl+a` then `H/J/K/L` |
| Reload config | `Ctrl+a` then `r` |

## Troubleshooting

### Icons/glyphs show as boxes or question marks

→ The Nerd Font isn't selected in Windows Terminal. Go to Settings → Profile → Appearance → Font face → **JetBrainsMono Nerd Font**.

### Starship not found after install (Linux)

→ The installer puts the binary in `/usr/local/bin`. Open a new shell or run `source ~/.zshrc`.

### Starship not found after winget install (Windows)

→ Open a new `pwsh` session. winget updates `%PATH%` at the machine level but the current session won't see it until restarted.

### pyenv: command not found (after opting in)

→ Open a new terminal. pyenv is loaded via `.zshrc` which only takes effect in a new shell.

### Permission denied on setup-linux.sh

```bash
chmod +x setup-linux.sh
```

### Native Linux font setup (non-WSL, without the Windows script)

```bash
mkdir -p ~/.local/share/fonts
curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.zip
echo "76f05ff3ace48a464a6ca57977998784ff7bdbb65a6d915d7e401cd3927c493c  JetBrainsMono.zip" | sha256sum -c
unzip JetBrainsMono.zip "JetBrainsMonoNerdFont*.ttf" -d ~/.local/share/fonts/
rm JetBrainsMono.zip
fc-cache -fv
```
