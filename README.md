# linux-utils

Idempotent bootstrap scripts that turn a fresh Ubuntu/Debian box into a ready-to-use
development machine.

The repository currently contains two generations of the same tool:

| | Script | Status |
|---|---|---|
| **v1 (monolith)** | [`setup/dev-setup.sh`](setup/dev-setup.sh) | Complete and functional — a single self-contained script. |
| **v2 (modular)** | [`main.sh`](main.sh) + [`lib/`](lib) + [`setup/`](setup) | Work in progress — a refactor of v1 into small, composable modules. |

If you just want a working machine setup today, use `setup/dev-setup.sh`. If you
want to contribute to the project, the interesting work is in `main.sh`,
`lib/` and `setup/`.

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
chmod +x setup/dev-setup.sh main.sh
./setup/dev-setup.sh
```

To run the in-progress v2 instead — same eight steps, with a requirements
preflight before the first one — use `./main.sh`. See [v2 status](#v2-status).

The run takes a few minutes. Every command's raw output is written to a timestamped
log file:

```
/tmp/setup-YYYYMMDD-HHMMSS.log
```

Re-running the script is safe. Most steps check whether their target is already
installed and skip if so; the ones that do not — the `apt` update, the PPA adds,
the base package install — are idempotent by nature.

## What gets installed

This is v1's package set. v2's base packages differ — see
[v2 status](#v2-status).

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
7. **Git configuration** — `user.name`, `user.email`, `core.editor` (`nano`),
   default branch `main`, `pull.rebase false`, and `color.ui auto`.
8. **SSH keys** — if `PRIVATE_KEY` / `PUBLIC_KEY` in the script are filled in, they
   are restored from base64. Otherwise a fresh ed25519 key is generated and the
   public key is printed so you can add it to GitHub/GitLab.

## Configuration

`setup/dev-setup.sh` has a config block near the top. Edit it before running:

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

## v2 status

`main.sh` covers the same eight steps as v1, but only two are ported:

| # | Step | v2 |
|---|---|---|
| 1 | System update & base packages | [`setup/base_packages.sh`](setup/base_packages.sh) |
| 2 | Docker Engine | [`setup/docker.sh`](setup/docker.sh) |
| 3–8 | Zsh, nvm, PHP, SDKMAN, Git, SSH | stubbed sections in `main.sh`, no code yet |

The v2-only features — the [preflight](#before-it-runs), the `ERR` trap,
`SETUP_ASSUME_YES`, `SOFT_PREFLIGHT` — do not exist in v1; v1 has no
confirmation prompt at all.

### Where v2 has already diverged from v1

- **A different base package set.** v2 keeps the PPAs and the apt update, but
  swaps the CLI set for a desktop-and-media one: `btop`, `fastfetch`,
  `synaptic`, `dconf-editor`, `gdm-settings`, `gnome-tweaks`,
  `gnome-shell-extension-manager`, `solaar`, `deluge`, `mpv`, `celluloid`,
  `libreoffice`, `grub-customizer`, `pipx`, plus `ubuntu-restricted-extras`.
  It does **not** install `jq`, `ripgrep`, `fzf`, `tree`, `bat`, `tmux`, or the
  `cat` / `fd` aliases — v1 does. Sections 3–8, once ported, are where the rest
  of v1's set would come back.
- **Docker's repo is added in deb822 format.** v2 writes
  `/etc/apt/sources.list.d/docker.sources` and keeps the upstream key
  ASCII-armored as `docker.asc`, referenced by `Signed-By`. v1 dearmors it into
  `docker.gpg` and writes a classic one-line `docker.list`. Both resolve to the
  same `download.docker.com/linux/ubuntu` repository, so either is fine on its
  own; installing v1 then v2 leaves the deb822 file behind.

### Known gaps in v2

- `setup/base_packages.sh` calls `add-apt-repository` but never installs
  `software-properties-common`, which provides that command. v1 installs it.
  It is preinstalled on a stock Ubuntu image, but not on a minimal one.
- `setup/docker.sh` adds you to the `docker` group only inside the install
  branch. On a machine that already has Docker, the group is never touched, so
  `docker` keeps asking for `sudo`.
- `add_custom_repositories` has no `command_exists`-style guard, and
  `run_or_die` is called unconditionally, so a re-run of v2 re-adds every PPA
  and reinstalls the whole base set. Harmless — `apt install` on an installed
  package is a no-op — but slower than v1's guarded steps, and the only step in
  either generation that is not re-runnable cheaply.

## Repository layout

```
linux-utils/
├── README.md
├── main.sh              # v2 entrypoint — owns shell options, logging, preflight
├── lib/
│   ├── ui.sh            # colors, banners, sections, log levels, spinner, markdown
│   ├── log.sh           # the run log file and the `run` command wrapper
│   ├── utils.sh         # command_exists, append_if_missing
│   └── preflight.sh     # machine detection, requirement checks, confirmation
└── setup/
    ├── dev-setup.sh     # v1 monolith — the full, working implementation
    ├── base_packages.sh # v2: apt repositories + base packages
    ├── docker.sh        # v2: Docker Engine from the official repo
    └── test-php.sh      # v2: scratch script for testing lib/ui.sh output
```

`lib/` holds the reusable pieces, `setup/` holds the steps. `main.sh` is the only
file that runs; everything else is sourced. The split mirrors the split inside
each step: a `setup/*.sh` file sources the libraries it needs from `../lib/`,
following the same pattern the libraries use among themselves.

## The `lib/` libraries

The libraries are layered by concern, and the split is strict:

> **`lib/*.sh` never calls `exit` and never changes the caller's shell options.**
> Every function returns a status instead. What ends the program — shell
> options, `IFS`, the `ERR` trap, `exit` — belongs to `main.sh`.

That is why `lib/ui.sh` is a pure presentation layer: no `set`, no `trap`, no
log file, no `/etc/os-release`, no markdown parsing, no `exit`.

### `lib/ui.sh` — presentation

| Function | Purpose |
|---|---|
| `banner "TEXT" [color]` | Print a boxed, centered title. The optional second arg colors the frame *and* the text. |
| `section "TEXT"` | Print a `▶` section header with a rule underneath. |
| `info` / `warn` / `error` / `success` / `step` | Colored single-line log levels. |
| `spinner_start "msg"` / `spinner_stop` | The spinner primitives `run` is built on. |
| `bullet "marker" "text"` | One list line with inline markdown rendered. |
| `md_inline "text"` | Terminal rendering of `` `code` `` (bold cyan) and `**bold**`. |
| `prompt_yes_no "question"` | Ask a `[Y/n]` question, return 0 for yes. Policy-free — no TTY or CI handling. |
| `UI_WIDTH` | Shared width, so banners and section rules line up. |

### `lib/log.sh` — the run log

| Symbol | Purpose |
|---|---|
| `run "Label" cmd …` | Run a command behind a spinner with its output appended to `$LOG_FILE`. On failure it prints the tail of the log and **returns** the command's status. |
| `log_tail [lines]` | The last N lines of the log, indented for the terminal. |
| `LOG_FILE` | Path to the current run's log. Export `LOG_FILE` before sourcing to override. |

### `lib/utils.sh` — generic helpers

| Function | Purpose |
|---|---|
| `command_exists "cmd"` | `command -v` with a quiet failure mode. |
| `append_if_missing file marker content` | Append content to a file only if the marker string is not already present — the idempotency primitive for editing dotfiles. |

### `lib/preflight.sh` — machine detection and confirmation

| Function | Purpose |
|---|---|
| `show_requirements [file]` | Render the `## Requirements` bullets of a markdown file as a numbered checklist. |
| `check_requirements [file]` | Verify the machine against every requirement, printing the observed value next to the verdict. Returns 1 if any check fails. |
| `preflight [file]` | `show_requirements` → `check_requirements` → `confirm`. Returns 1 if a check failed, 130 if the user declined. `main.sh` turns that into an exit. |
| `confirm "prompt"` | `prompt_yes_no` plus the auto-approve policy: `SETUP_ASSUME_YES=1`, or no TTY. |
| `readme_section "Heading" [file]` | Print the body of any `## Heading` in a markdown file, stopping at the next heading. |
| `_os_release` | Read a value out of `/etc/os-release`. |

Each requirement needs a check, registered as a `key|predicate|detail` row in
`_REQ_CHECKS`. The `key` must appear as a whole word in the matching README
bullet, which supplies the label that gets printed — so the README stays the
source of truth for wording and the table only carries machine-specific logic.

| Key | Predicate | Detail |
|---|---|---|
| `linux` | `_req_check_linux` | `kernel <uname -sr>` |
| `bash` | `_req_check_bash` | `bash <version>` |
| `ubuntu` | `_req_check_apt` | `<PRETTY_NAME>, apt-get: <path>` |
| `sudo` | `_req_check_sudo` | `sudo: <path>`, or that you are root |

Adding a bullet to the README without a matching row is reported rather than
silently ignored:

```
  ›  git available — no automated check, unverified
  ›  1 requirement(s) could not be verified automatically
```

and a row whose bullet has disappeared from the README is reported the other way
round:

```
  !  check 'sudo' has no matching requirement in /path/to/README.md
```

Matching normalises the bullet first: markdown, a trailing parenthetical and
anything after an em/en dash are stripped, and the result is lowercased. So
`` `sudo` available — the script will prompt for your password `` matches the key
`sudo`.

## Before it runs

`main.sh` calls `preflight` right after the banner, so every run starts by showing
the requirements and proving them against your machine:

```
▶  Requirements
────────────────────────────────────────────────────────────
  1.  Linux (the script hard-fails on anything else)
  2.  bash 4.0 or newer
  3.  Ubuntu or Debian, apt based
  4.  sudo available — the script will prompt for your password

▶  Environment check
────────────────────────────────────────────────────────────
  ✓  Linux (the script hard-fails on anything else) — kernel Linux 6.6.13-1-default
  ✓  bash 4.0 or newer — bash 5.2.21(1)-release
  ✓  Ubuntu or Debian, apt based — Ubuntu 24.04.1 LTS, apt-get: /usr/bin/apt-get
  ✓  sudo available — the script will prompt for your password — sudo: /usr/bin/sudo
  ✓  All requirements satisfied
  ›  Run the setup now? [Y/n]
```

The wording of each requirement is **not** hardcoded anywhere — it is parsed out
of the [`## Requirements`](#requirements) section of this file, so editing the
bullets above is enough to change what the script displays and checks. Only the
machine-specific logic lives in `lib/preflight.sh`, in the `_REQ_CHECKS` table
documented above. The README path is resolved relative to `lib/`, so it works
from any working directory; set `PREFLIGHT_README` to point somewhere else.

A failed check aborts before anything is installed. Two escape hatches:

| Variable | Effect |
|---|---|
| `SETUP_ASSUME_YES=1` | Skip the `[Y/n]` prompt. Implied automatically when stdout is not a TTY (CI, pipes). |
| `SOFT_PREFLIGHT=1` | Report failed checks as warnings and continue instead of aborting. |

The legacy `UI_README` name is still honoured alongside it. This matters if you
edit the [Requirements](#requirements) bullets: the preflight reads the wording
from there at run time, so a typo in that section shows up on your terminal as
a mismatched or unverified check.

### When a step goes wrong

A step that fails through `run_or_die` prints the tail of the log and ends the
run, which covers anything invoked as a command. Failures *outside* a `run` —
a failed `[[ ]]` test, an unset variable under `set -u`, a bad expansion — are
caught by the `ERR` trap in `main.sh`, enabled for functions by `set -E`:

```
  ✗  unexpected failure at /path/to/linux-utils/setup/docker.sh:56 (exit 1)
```

The reported line is where the failing command actually is, not where the
function was called from, and the exit status is the command's own.

## Writing a new module

The convention is one file per concern under `setup/`, exposing a single
`*_setup` function that `main.sh` calls. The skeleton mirrors how the `lib/`
files source each other — resolve the directory from `BASH_SOURCE` once, source
siblings relative to it, and guard against double sourcing:

```bash
#!/usr/bin/env bash

# A step of main.sh, not a standalone program.
[[ -n "${_SOMETHING_SH_LOADED:-}" ]] && return
readonly _SOMETHING_SH_LOADED=1

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"
source "$_setup_dir/../lib/utils.sh"

install_something() {
    sudo apt install -y something
}

something_setup() {
    section 'Installing something'

    if command_exists something; then
        info "Already installed ($(something --version)). Skipping."
    else
        run_or_die 'Installing something' install_something
    fi
}
```

Then source it from `main.sh` alongside the other libraries and add a numbered
section for the `*_setup` call. Sections 3–8 (Zsh, nvm, PHP, SDKMAN, Git, SSH)
are stubbed out and waiting to be ported from `setup/dev-setup.sh`.

A few rules keep the layering intact:

- **A module does not set shell options.** `main.sh` owns `set -eEuo pipefail`
  and `IFS`; a module is a step of the program, not a shell of its own. Note
  that `IFS` is newline+tab only, so always quote expansions in a module.
- **A module calls `run_or_die`,** which `main.sh` defines. `run` in
  `lib/log.sh` only returns a status — the entrypoint is what decides a failed
  step ends the run.
- **A module never calls `preflight`.** The entrypoint does it once, before the
  first section.
- **A new hard prerequisite needs two edits:** a `key|predicate|detail` row in
  `_REQ_CHECKS` in `lib/preflight.sh`, and a matching bullet in this file's
  [Requirements](#requirements) section. Miss either and the run says so.
- **Indent is 4 spaces, no tabs,** in every `.sh` file — one level per block,
  including the payload of a `bash -c '…'` string. Here-doc bodies start at
  column 0, because `<<EOF` strips the indentation but not the content.

## Notes

- **Docker group:** `usermod -aG docker "$USER"` grants root-equivalent access. Only
  do this on a machine you fully trust.
- **Third-party PPAs:** v2's `setup/base_packages.sh` adds seven personal package
  archives (LibreOffice, Solaar, mpv, deadbeef, gnome-mpv, grub-customizer, GDM
  settings) and installs packages straight out of them, so dropping the `add-apt-repository`
  lines means also dropping the packages that only exist there. v1 adds none of
  these; its only third-party archive is Ondřej's PHP PPA, in section 5.
- **Shell options live in the entrypoint.** `set -e` inside a sourced file does
  not reliably enable errexit, which is why `main.sh` sets it and the libraries
  do not. `set -E` is there so the `ERR` trap also fires for failures inside
  functions, which is where all the real work happens.
- **`run_or_die` is a one-liner,** not a separate concern: `run "$@" || exit $?`.
  A module calls it because a failed step should end the run, but the decision
  to end it belongs to the entrypoint. `run` in `lib/log.sh` never exits.

## License

MIT — use it, fork it, adapt it to your own machine.
