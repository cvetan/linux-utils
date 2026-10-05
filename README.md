# linux-utils

Idempotent bootstrap scripts that turn a fresh Ubuntu box — or an Ubuntu
derivative such as Linux Mint, Pop!_OS or Zorin — into a ready-to-use
development machine.

The repository currently contains two generations of the same tool:

| | Script | Status |
|---|---|---|
| **v1 (monolith)** | `setup/dev-setup.sh` | Legacy, superseded — kept for reference until the v2 port finishes. |
| **v2 (modular)** | [`main.sh`](main.sh) + [`lib/`](lib) + [`setup/`](setup) | The one to run. A refactor of v1 into small, composable modules. |

Run `main.sh`. The interesting work is in `main.sh`, `lib/` and `setup/`.

---

## Requirements

- Linux (the script hard-fails on anything else)
- `bash` 4.0 or newer
- Ubuntu or an Ubuntu derivative, `apt` based
- `sudo` available — the script will prompt for your password

## Quick start

```bash
git clone git@github.com:cvetan/linux-utils.git
cd linux-utils
chmod +x main.sh
./main.sh
```

The run takes a few minutes. Every command's raw output is written to a timestamped
log file:

```
/tmp/setup-YYYYMMDD-HHMMSS.log
```

Re-running the script is safe. Most steps check whether their target is already
installed and skip if so; the ones that do not — the `apt` update, the PPA adds,
the base package install — are idempotent by nature.

## One-file installer

Every release ships a self-extracting archive built with
[makeself](https://makeself.io/): the whole tool as a single
`linux-utils-<tag>.run`. No clone, and nothing to install first — `bash`, `tar`
and `gzip`, all of which a machine being set up already has.

```bash
curl -fsSLO https://github.com/cvetan/linux-utils/releases/latest/download/linux-utils-v2.0.0.run
chmod +x linux-utils-v2.0.0.run
./linux-utils-v2.0.0.run
```

The archive extracts itself into a temporary directory, runs `main.sh` from
there, and deletes the directory when the run finishes. Its layout inside is the
same as a clone's, because every path in this repo is resolved from
`BASH_SOURCE` rather than the working directory. The stub's own flags work as
documented:

| Flag | Effect |
|---|---|
| `--info` | What is inside, without extracting. |
| `--check` | Verify the embedded checksums. |
| `--noexec` | Extract without running the setup. |
| `--keep` | Leave the extracted tree on disk. |
| `--target dir` | Extract into `dir` and run from there. |

**Do not pipe it into `bash`** (`curl … | bash`). With no terminal the preflight
prompt auto-approves itself and `sudo` has no way to ask for your password, so a
run that should have stopped at the confirmation will not.

Check a download against the `.sha256` asset published with it:

```bash
sha256sum -c linux-utils-v2.0.0.run.sha256
```

### Building the archive

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds the
archive and attaches it to a published release;
[`.github/workflows/build.yml`](.github/workflows/build.yml) builds the same
artifact on every pull request and push and hands it back as a workflow
artifact, so it can be tried on a throwaway machine before a tag goes out. Both
call the same script, which is the whole of what CI does:

```bash
./scripts/build-archive.sh              # version from `git describe`, output in dist/
./scripts/build-archive.sh v2.0.0       # explicit version
./scripts/build-archive.sh v2.0.0 dist  # explicit output directory
```

It wants makeself — `sudo apt install makeself`, or point `$MAKESELF` at one you
unpacked yourself — and writes `dist/linux-utils-<version>.run` with a
`.sha256` beside it. Nothing in it runs the setup: the archive is extracted with
`--noexec` and inspected, because a release job has no business installing apt
packages on a runner.

Two things about it are deliberate. The payload is an explicit allowlist —
`main.sh`, `README.md`, `lib/`, `setup/` without the v1 monolith — because the
preflight parses the `## Requirements` bullets out of the bundled README at run
time, so an archive missing it extracts fine and then quietly verifies nothing.
And the build refuses to publish an archive it has not checked first: the
embedded checksums, the file list, the executable bit on `main.sh`, `bash -n`
over every packaged script, and a read of the requirements back out of the
extracted copy.

## Testing in a container

[`Dockerfile`](Dockerfile) builds a disposable sandbox — a bare Ubuntu, a
non-root `tester` with passwordless `sudo`, and a `policy-rc.d` that keeps apt
maintainer scripts from trying to start services in a container with no init.
The repository is **not** baked in: `scripts/docker-test.sh` takes a frozen
snapshot of the working tree and mounts that read-only at `/work`. Each
invocation copies the tree once, up front, so a run is reproducible and cannot
be corrupted by an edit made while it is in flight, and every run starts from a
clean filesystem.

```bash
scripts/docker-test.sh              # 26.04, the default
scripts/docker-test.sh 22.04 24.04 26.04
```

Each release is built once into `linux-utils-test:<release>` and run in a fresh
`docker run --rm` container. Because the image is immutable and the container is
discarded, a second run is a clean install again; the image itself is never
modified. To test idempotency on an *already-configured* machine instead, run
the setup twice in one container:

```bash
RUNS=2 scripts/docker-test.sh 26.04
```

The base image is deliberately bare — `curl` and `software-properties-common`
are not installed — so the run exercises the bootstrap in
`setup/base_packages.sh` rather than being handed its prerequisites. This needs
a working Docker daemon and outbound network (Launchpad PPAs, Oh-My-Zsh, VS
Code, Docker's repository), and the full desktop/media set makes a run several
GB and several minutes per release.

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

`main.sh` runs four of the eight steps, plus the VS Code module that is not one
of them:

| # | Step | v2 |
|---|---|---|
| 1 | System update & base packages | [`setup/base_packages.sh`](setup/base_packages.sh) |
| 2 | Docker Engine | [`setup/docker.sh`](setup/docker.sh) |
| 3 | Zsh + Oh-My-Zsh | [`setup/zsh.sh`](setup/zsh.sh) |
| 4 | Visual Studio Code (not a v1 step) | [`setup/vscode.sh`](setup/vscode.sh) |
| 7 | SDKMAN + Java | [`setup/sdkman.sh`](setup/sdkman.sh) |
| 5–6, 8–9 | nvm, PHP, Git, SSH | stubbed sections in `main.sh`, no code yet |

[`setup/vscode.sh`](setup/vscode.sh) installs Visual Studio Code from
Microsoft's apt repository. It is called from `main.sh` as step 4; remove the
`vscode_setup` call there if a machine should not get it.

The v2-only features — the [preflight](#before-it-runs), the `ERR` trap,
`SETUP_ASSUME_YES`, `SOFT_PREFLIGHT` — do not exist in v1; v1 has no
confirmation prompt at all.

### Where v2 has already diverged from v1

- **A different base package set.** v2 keeps the PPAs and the apt update, and
  adds a desktop-and-media set on top: `btop`, `fastfetch`, `synaptic`,
  `dconf-editor`, `gdm-settings`, `gnome-tweaks`,
  `gnome-shell-extension-manager`, `solaar`, `deluge`, `mpv`, `celluloid`,
  `libreoffice`, `grub-customizer`, `pipx`, plus `ubuntu-restricted-extras`.
  It also installs `bat` and `fd-find` (aliased to `cat` and `fd`, with the
  `batcat` → `bat` symlink) and `tmux`. It does **not** install v1's `jq`,
  `ripgrep`, `fzf` or `tree`; sections 5–9, once ported, are where the rest of
  v1's set would come back.
- **Docker's repo is added in deb822 format.** v2 writes
  `/etc/apt/sources.list.d/docker.sources` and keeps the upstream key
  ASCII-armored as `docker.asc`, referenced by `Signed-By`. v1 dearmors it into
  `docker.gpg` and writes a classic one-line `docker.list`. Both resolve to the
  same `download.docker.com/linux/ubuntu` repository, so either is fine on its
  own; installing v1 then v2 leaves the deb822 file behind.
- **Powerlevel10k runs in `powerline` mode, not `nerdfont-complete`,** to match
  the `fonts-powerline` that step 1 actually installs. v1 used
  `nerdfont-complete`, which needs a Nerd Font and renders boxes without one.

### Known gaps in v2

- `add_custom_repositories` re-adds every PPA and reinstalls the whole base set
  on each run. Harmless — `apt install` on an installed package is a no-op, and
  `add-apt-repository` on an already-added PPA is a no-op — but slower than v1's
  guarded steps, and the only step in either generation that is not re-runnable
  cheaply.
- Of the seven PPAs, only two supply a package that is not in the Ubuntu archive
  (`gdm-settings` and `grub-customizer`). The other five are kept for newer
  builds of packages the archive already has; dropping them is a separate call.

## Repository layout

```
linux-utils/
├── .github/
│   └── workflows/
│       ├── build.yml          # build + verify the .run on every PR and push
│       └── release.yml        # …and attach it to a published release
├── README.md
├── Dockerfile           # disposable sandbox image for scripts/docker-test.sh
├── .dockerignore
├── main.sh              # v2 entrypoint — owns shell options, logging, preflight
├── lib/
│   ├── ui.sh            # colors, banners, sections, log levels, spinner, markdown
│   ├── log.sh           # the run log file and the `run` command wrapper
│   ├── utils.sh         # command_exists, _sudo, append_if_missing
│   └── preflight.sh     # machine detection, requirement checks, confirmation
├── scripts/
│   ├── build-archive.sh # package the repo into a makeself .run for a release
│   └── docker-test.sh   # run main.sh on a clean Ubuntu in a throwaway container
└── setup/
    ├── dev-setup.sh     # v1 monolith — legacy, superseded
    ├── base_packages.sh # v2: apt repositories + base packages
    ├── docker.sh        # v2: Docker Engine from the official repo
    ├── zsh.sh           # v2: zsh, Oh-My-Zsh, powerlevel10k, base .zshrc
    └── vscode.sh        # v2: VS Code from Microsoft's apt repository
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
| `prompt_choice "question" default item …` | Numbered selection menu on stderr; the chosen item on stdout. Policy-free — no TTY or CI handling. |
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
| `choose "prompt" default item …` | `prompt_choice` plus the auto-select policy: `SETUP_ASSUME_YES=1`, or no TTY, takes `default`. |
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
  3.  Ubuntu or an Ubuntu derivative, apt based
  4.  sudo available — the script will prompt for your password

▶  Environment check
────────────────────────────────────────────────────────────
  ✓  Linux (the script hard-fails on anything else) — kernel Linux 6.6.13-1-default
  ✓  bash 4.0 or newer — bash 5.2.21(1)-release
  ✓  Ubuntu or an Ubuntu derivative, apt based — Ubuntu 24.04.1 LTS, apt-get: /usr/bin/apt-get
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

### Unattended runs

Two things must be true for `main.sh` to run with no terminal:

- `SETUP_ASSUME_YES=1` (implied automatically when stdout is not a TTY) so the
  confirmation is skipped.
- The invoking user is `root`, or has passwordless `sudo`. When a TTY is
  present the script caches `sudo` credentials once; an unattended run cannot
  answer a password prompt, so `sudo` must not ask.

Non-interactive apt is handled for you: the entrypoint exports
`DEBIAN_FRONTEND=noninteractive`, `NEEDRESTART_MODE=a` and
`APT_LISTCHANGES_FRONTEND=none`, and pre-accepts the core-fonts EULA that
`ubuntu-restricted-extras` pulls in. The base package set is split into a small
core (missing → the run stops) and desktop/media extras (missing → warned about
and skipped). That is what makes the same script work across 22.04, 24.04 and
26.04, where packages come and go — for example `fastfetch` is absent before
24.04, and a PPA that publishes no suite for the release is skipped rather than
failing the run.

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
    _sudo apt install -y something
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
section for the `*_setup` call. Sections 5, 6, 8 and 9 (nvm, PHP, Git, SSH)
are still stubbed out and waiting to be ported from `setup/dev-setup.sh`.

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
- **A new file needs two edits too:** a `source` line in `main.sh`, and an entry
  in `REQUIRED_FILES` in `scripts/build-archive.sh`. The archive payload is an
  allowlist, so a module that is not listed works from a clone and is silently
  missing from a release.
- **Indent is 4 spaces, no tabs,** in every `.sh` file — one level per block,
  including the payload of a `bash -c '…'` string. Here-doc bodies start at
  column 0, because `<<EOF` strips the indentation but not the content.

## Notes

- **Docker group:** `usermod -aG docker "$(id -un)"` grants root-equivalent access.
  Only do this on a machine you fully trust. `id -un` rather than `$USER` because
  `$USER` is unset under `env -i`, which is fatal with `set -u`.
- **Third-party PPAs:** v2's `setup/base_packages.sh` adds seven personal package
  archives (LibreOffice, Solaar, mpv, deadbeef, gnome-mpv, grub-customizer, GDM
  settings) and installs packages straight out of them, so dropping the `add-apt-repository`
  lines means also dropping the packages that only exist there. v1 adds none of
  these; its only third-party archive is Ondřej's PHP PPA, in section 5.
- **A PPA without a suite for your Ubuntu is skipped, never fatal.** `apt update`
  exits 100 on any configured repository it cannot fetch, so one dead PPA would
  otherwise abort the whole run at step 1 — which is exactly what
  `ppa:ubuntuhandbook1/mpv` did on Ubuntu 26.04, having published nothing for
  `resolute`. Each PPA is probed with a `HEAD` request against its `Release` file
  first, and skipped with a warning if there is no suite for
  `$VERSION_CODENAME`. Don't "simplify" this back to bare `add-apt-repository`
  lines; it will break again on the next Ubuntu release.
- **The `ERR` trap stays out of subshells.** `set -E` makes it fire inside
  `$(...)` too, where `exit` only ends the subshell — so a handler that reported
  and exited there would print a trace for a failure the enclosing command then
  goes on to report as success. That is how `info "Docker already installed
  ($(docker --version))"` printed a bogus error and exited 0 against a broken
  `docker` shim. `_on_error` now returns early when `BASH_SUBSHELL > 0`. The
  consequence to remember: **a call site that puts a fallible command in a
  command substitution discards the failure**, so it needs its own `||` fallback
  (`docker.sh`, `zsh.sh` and `vscode.sh` all do).
- **The spinner is a no-op without a TTY.** Its frames are newline-less writes
  that only make sense when a terminal re-renders the line; piped to a file,
  stdout is block-buffered and the frames flush after the following output,
  landing in the middle of the next section.
- **Shell options live in the entrypoint.** `set -e` inside a sourced file does
  not reliably enable errexit, which is why `main.sh` sets it and the libraries
  do not. `set -E` is there so the `ERR` trap also fires for failures inside
  functions, which is where all the real work happens.
- **`run_or_die` is a one-liner,** not a separate concern: `run "$@" || exit $?`.
  A module calls it because a failed step should end the run, but the decision
  to end it belongs to the entrypoint. `run` in `lib/log.sh` never exits.

## License

MIT — use it, fork it, adapt it to your own machine.
