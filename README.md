# linux-utils

Idempotent bootstrap scripts that turn a fresh Ubuntu/Debian box into a ready-to-use
development machine.

The repository currently contains two generations of the same tool:

| | Script | Status |
|---|---|---|
| **v1 (monolith)** | [`dev-setup.sh`](dev-setup.sh) | Complete and functional — a single self-contained script. |
| **v2 (modular)** | [`main.sh`](main.sh) + [`lib/`](lib) | Work in progress — a refactor of v1 into small, composable modules. |

If you just want a working machine setup today, use `dev-setup.sh`. If you want to
contribute to the project, the interesting work is in `main.sh` / `lib/`.

---

## Requirements

- Linux (the script hard-fails on anything else)
- `bash` 4.0 or newer
- Ubuntu or Debian, `apt` based
- `sudo` available — the script will prompt for your password

## Quick start

```bash
git clone git@github.com:cvetan/linux-utils.git
cd linux-utils
chmod +x dev-setup.sh main.sh
./dev-setup.sh
```

The run takes a few minutes. Every command's raw output is written to a timestamped
log file:

```
/tmp/setup-YYYYMMDD-HHMMSS.log
```

Re-running the script is safe. Each step checks whether its target is already
installed and skips if so.

## What gets installed

1. **Base system & CLI tools** — `build-essential`, `curl`, `wget`, `git`, `unzip`,
   `jq`, `ripgrep`, `fzf`, `tmux`, `tree`, `htop`, `zsh`, plus `bat` and `fd`
   (aliased from Ubuntu's `batcat` and `fdfind`).
2. **Docker Engine** — installed from Docker's official apt repository (not
   distro packages), including Buildx and Compose v2 plugins. Conflicting legacy
   packages (`docker.io`, `podman-docker`, `containerd`, …) are removed first, and
   your user is added to the `docker` group.
3. **Zsh + Oh-My-Zsh** — installed without prompts, and set as the default shell.
   Your `.zshrc` gets idempotently appended aliases and `PATH` entries.
4. **nvm + Node.js** — version is configurable via `NODE_VERSION` (defaults to
   `lts/*`).
5. **PHP + Composer + Laravel** — PHP 8.3 from Ondřej's PPA with the common
   extensions, Composer installed to `/usr/local/bin` after a SHA-384 checksum
   verification, and the global `laravel` installer.
6. **SDKMAN + Java** — version is configurable via `JAVA_VERSION`.
7. **Git configuration** — `user.name`, `user.email`, `core.editor`, default branch
   `main`, and `pull.rebase false`.
8. **SSH keys** — if `PRIVATE_KEY` / `PUBLIC_KEY` in the script are filled in, they
   are restored from base64. Otherwise a fresh ed25519 key is generated and the
   public key is printed so you can add it to GitHub/GitLab.

## Configuration

`dev-setup.sh` has a config block near the top. Edit it before running:

```bash
GIT_NAME="Your Name"
GIT_EMAIL="you@example.com"
NODE_VERSION="lts/*"      # "20", "22", "lts/*", ...
JAVA_VERSION="21.0.2-tem" # run `sdk list java` to browse available IDs

# Leave both empty to generate a new key instead.
PRIVATE_KEY="$(base64 -w0 ~/.ssh/id_ed25519)"
PUBLIC_KEY="$(base64 -w0 ~/.ssh/id_ed25519.pub)"
```

> **Do not commit real keys.** Keep `PRIVATE_KEY` empty in any pushed copy, or
> add it to `.gitignore` before setting it.

## After the run

A few changes need a new login to take effect:

1. `exec zsh` (or log out and back in) to pick up the shell, `nvm`, and SDKMAN setup.
2. Re-login so the `docker` group membership applies — otherwise `docker` still
   asks for `sudo`.
3. If a new SSH key was generated, add the printed public key to GitHub/GitLab.

## Repository layout

```
linux-utils/
├── README.md
├── main.sh              # v2 entrypoint — orchestrates the modular setup
├── dev-setup.sh         # v1 monolith — the full, working implementation
├── base_packages.sh     # v2: apt repositories + base packages
├── docker.sh            # v2: Docker Engine from the official repo
├── test-php.sh          # v2: scratch script for testing lib/ui.sh output
└── lib/
    └── ui.sh            # v2: colors, banners, sections, logging, spinner
```

## The `lib/ui.sh` toolkit

`lib/ui.sh` is the shared UI layer for the modular scripts. It has no external
dependencies, guards against double-sourcing, and enforces strict mode.

| Function | Purpose |
|---|---|
| `banner "TEXT"` | Print a boxed, centered title. Optional second arg sets the color. |
| `section "TEXT"` | Print a `▶` section header with a rule underneath. |
| `info` / `warn` / `error` / `success` / `step` | Colored single-line log levels. |
| `run "Label" cmd …` | Run a command behind a spinner, with output redirected to the log file. On failure it dumps the last 20 log lines and exits. |
| `spinner_start "msg"` / `spinner_stop` | The spinner primitives `run` is built on. |
| `command_exists "cmd"` | `command -v` with a quiet failure mode. |
| `append_if_missing file marker content` | Append content to a file only if the marker string is not already present — the idempotency primitive for editing dotfiles. |
| `show_requirements [file]` | Render the `## Requirements` bullets of a markdown file as a numbered checklist, with `` `code` `` and `**bold**` styled. |
| `check_requirements` | Verify the machine against each requirement, printing the observed value next to the verdict. Returns non-zero if any check fails. |
| `preflight [file]` | `show_requirements` → `check_requirements` → `confirm`. The one-liner called at the top of an entrypoint. |
| `confirm "prompt"` | `[Y/n]` gate. Auto-approves when `SETUP_ASSUME_YES=1` or when there is no TTY, so it is CI-safe. |
| `readme_section "Heading" [file]` | Print the body of any `## Heading` in a markdown file, stopping at the next heading. The parser behind `show_requirements`. |
| `bullet "marker" "text"` | One checklist line with inline markdown rendered. |
| `md_inline "text"` | Terminal rendering of `` `code` `` (bold cyan) and `**bold**` (stripped). |
| `LOG_FILE` | Path to the current run's log file. |

## Before it runs

`main.sh` calls `preflight` right after the banner, so every run starts by showing
the requirements and proving them against your machine:

```
▶  Requirements
──────────────────────────────────────────────────
  1.  Linux (the script hard-fails on anything else)
  2.  bash 4.0 or newer
  3.  Ubuntu or Debian, apt based
  4.  sudo available — the script will prompt for your password

▶  Environment check
──────────────────────────────────────────────────
  ✓  Linux — kernel Linux 6.6.13-1-default
  ✓  bash 4.0+ — bash 5.2.21(1)-release
  ✓  Ubuntu or Debian, apt-based — Ubuntu 24.04.1 LTS, apt-get: /usr/bin/apt-get
  ✓  sudo available — sudo: /usr/bin/sudo
  ✓  all requirements satisfied
  ›  Run the setup now? [Y/n]
```

The list is **not** hardcoded in `ui.sh` — it is parsed out of the
[`## Requirements`](#requirements) section of this file, so editing the bullets
above is enough to change what the script displays. The path is resolved
relative to `lib/ui.sh`, so it works from any working directory; set `UI_README`
to point somewhere else.

A failed check aborts before anything is installed. Two escape hatches:

| Variable | Effect |
|---|---|
| `SETUP_ASSUME_YES=1` | Skip the `[Y/n]` prompt. Implied automatically when stdout is not a TTY (CI, pipes). |
| `SOFT_PREFLIGHT=1` | Report failed checks as warnings and continue instead of aborting. |

## Writing a new module

The convention is one file per concern, exposing a single `*_setup` function that
`main.sh` calls. The skeleton:

```bash
#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

install_something() {
    sudo apt install -y something
}

something_setup() {
    section 'Installing something'

    if command_exists something; then
        info "Already installed ($(something --version)). Skipping."
    else
        run 'Installing something' install_something
    fi
}
```

Then add a numbered section in `main.sh`. Sections 3–8 (Zsh, nvm, PHP, SDKMAN, Git,
SSH) are stubbed out and waiting to be ported from `dev-setup.sh`.

A module never has to call `preflight` — the entrypoint does it once, before the
first section. If your module introduces a new hard prerequisite, add it as a
`predicate|detail` row in the `check_requirements` table in `lib/ui.sh` and a
matching bullet in this file's [Requirements](#requirements) section, so the
displayed list and the actual checks stay in sync.

## Notes

- **Docker group:** `usermod -aG docker "$USER"` grants root-equivalent access. Only
  do this on a machine you fully trust.
- **Third-party PPAs:** the setup adds several personal package archives (LibreOffice,
  mpv, Solaar, deadbeef, grub-customizer, GDM settings). They are optional — remove
  them from `base_packages.sh` if you'd rather stay on the official repos.
- **Known issue in the v2 refactor:** `main.sh` sources `./lib/base_packages.sh` and
  `./lib/docker.sh`, but those two files currently live in the repository root rather
  than in `lib/`. Move them into `lib/` (or update the `source` paths in `main.sh`)
  before running the v2 entrypoint.

## License

MIT — use it, fork it, adapt it to your own machine.
