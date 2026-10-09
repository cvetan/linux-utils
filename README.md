# linux-utils

Idempotent bootstrap scripts that turn a fresh Ubuntu box — or an Ubuntu
derivative such as Linux Mint, Pop!_OS or Zorin — into a ready-to-use
development machine.

The tool is modular: [`main.sh`](main.sh) is the entrypoint, [`lib/`](lib) holds
the reusable pieces, and [`setup/`](setup) holds one file per step. Run
`main.sh`; the interesting work is in those three places.

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
`main.sh`, `README.md`, `lib/` and `setup/` — because the preflight parses the
`## Requirements` bullets out of the bundled README at run time, so an archive
missing it extracts fine and then quietly verifies nothing. And the build
refuses to publish an archive it has not checked first: the embedded checksums,
the file list, the executable bit on `main.sh`, `bash -n` over every packaged
script, and a read of the requirements back out of the extracted copy.

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
GB and several minutes per release. The image build retries up to three times
against transient registry failures (a Docker Hub auth outage once failed every
run before it started), and the container run streams `main.sh`'s output live:
a run that prints moving step lines for many minutes is normal, not a hang.

## What gets installed

`main.sh` runs the modules below in order; see [Status](#status).

1. **System update & base packages** — `apt update` and `apt upgrade`, the
   `universe` and `multiverse` components, and the third-party PPAs listed under
   [Notes](#notes). The package set is split in three: a small core the run
   cannot continue without (`build-essential`, `curl`, `wget`, `zip`, `unzip`,
   `git`, `zsh`, `gnupg`, `ca-certificates`, `lsb-release`, `xclip`, `htop`,
   `tmux`); a best-effort desktop-neutral set that suits any desktop or none
   (`ubuntu-restricted-extras`, `bat`, `fd-find`, `xsel`, `btop`, `fastfetch`,
   `synaptic`, `apt-xapian-index`, `powerline`, `fonts-powerline`,
   `libglib2.0-dev-bin`, `solaar`, `deluge`, `mpv`, `libreoffice`,
   `libreoffice-style-sifr`, `pipx`, plus the PPA-only `grub-customizer`); and
   a desktop-specific set picked from the detected desktop environment: GNOME
   gets `gnome-shell-extension-manager`, `gnome-tweaks`, `dconf-editor` and
   `celluloid` (a GTK frontend for `mpv`); Cinnamon, MATE, Budgie and Unity get
   `dconf-editor` (they read their settings from dconf); Xfce gets
   `xfce4-goodies`; KDE, LXQt and an undetected desktop get no extras at all.
   Detection reads `SETUP_DESKTOP` first, then `XDG_CURRENT_DESKTOP`,
   `XDG_SESSION_DESKTOP` and `DESKTOP_SESSION`, then the session saved in
   `/var/lib/AccountsService/users/<you>`, then the installed session package —
   with two installed desktops counting as ambiguous rather than guessed. A
   package the running release does not carry is warned about and skipped,
   never fatal; only a missing core package stops the run. `batcat` is
   symlinked to `bat`.
2. **Zsh + Oh-My-Zsh** — installed without prompts, and set as the default shell.
   Powerlevel10k runs in `powerline` mode to match the `fonts-powerline` that
   step 1 installs, and your `.zshrc` gets idempotently appended aliases and
   `PATH` entries. Runs before the installers below because they write their init
   into your shell config.
3. **Docker Engine** — installed from Docker's official apt repository (not
   distro packages), including Buildx and Compose v2 plugins. Conflicting legacy
   packages (`docker.io`, `podman-docker`, `containerd`, …) are removed first, and
   your user is added to the `docker` group.
4. **Visual Studio Code** — installed from Microsoft's apt repository.
   Deselect it at the `Steps to run` prompt (or `SKIP_STEPS=vscode`) if a
   machine should not get it.
5. **Node.js + npm** — the distribution's own Node and npm, no third-party PPA
   and no nvm, so the version tracks the Ubuntu release (12 on 22.04, 18 on
   24.04, 22 on 26.04). Debian/Ubuntu build `nodejs` `--without-npm`, so `npm`
   (which also ships `npx`) is a separate package. This is local tooling only:
   projects run their own Node from their Docker setup, and the module warns
   when the archive version is past end-of-life. Global npm packages go to
   `~/.local` (`NPM_PREFIX`), so `npm install -g` needs no sudo and its bins land
   in `~/.local/bin`.
6. **PHP + Composer** — the distribution's own PHP CLI, no third-party PPA, so
   the version tracks the Ubuntu release (8.1 on 22.04, 8.3 on 24.04, 8.5 on
   26.04), with the common extensions. Composer is installed to
   `~/.local/bin/composer` after a SHA-384 checksum verification.
7. **SDKMAN + Java** — SDKMAN!, with a Temurin JDK chosen from a menu (or pinned
   with `JAVA_VERSION`).
8. **Git configuration** — the global identity (`user.name` / `user.email`,
   prompted only when not already set), the default branch name (default `main`),
   `push.default current` and a set of everyday defaults. See
   [`setup/git.sh`](setup/git.sh).
9. **SSH keys** — the plan is made up front: before anything is installed, the
   run reports whether `SSH_KEYS_BUNDLE` is set or keys are present in `~/.ssh`,
   asks whether to use them, and if you have neither it says SSH setup will be
   skipped for now. It then adopts the keys you copy into `~/.ssh`: tightening
   their permissions, and for any key without a host mapping asking which host it
   belongs to and writing `~/.ssh/linux-utils.conf`. No key is ever overwritten,
   and nothing is fetched from the network. Set `SSH_KEYS_BUNDLE` (a directory,
   `.tar.gz`, `.tar` or `.zip`) to install from an offline bundle instead — the
   reproducible, non-interactive path. See [`setup/ssh.sh`](setup/ssh.sh).
10. **Firefox** (optional) — only runs when Firefox is installed as a snap and no
    deb build is present; on any other machine it reports the skip and does
    nothing. It asks before doing anything, then removes the snap, purges the
    snap-transition package, adds `ppa:mozillateam/ppa` with a `1001` pin so its
    build is preferred, and installs `firefox` as a deb. See
    [`setup/firefox.sh`](setup/firefox.sh).
11. **Xbox Wireless Adapter** (optional) — only runs when the Microsoft dongle is
    attached; on any other machine it reports the skip and does nothing. The
    dongle is found dynamically (Microsoft vendor `045e`, identified by its
    product string or the `mt76x2u` WiFi driver it binds to), not from a fixed
    product-ID list, and the udev rule is generated from the `idProduct`(s)
    actually found. It asks before doing anything, then installs a rule that
    de-authorizes the dongle so Linux leaves it alone and a Windows dual boot
    keeps its controller pairing. The adapter no longer works on Linux
    afterwards — that is the point. See [`setup/xbox.sh`](setup/xbox.sh).
12. **NVIDIA drivers** (optional) — only runs when an NVIDIA display controller
    is detected; on any other machine it reports the skip and does nothing. It
    asks before installing, then installs the **latest proprietary** branch
    (plain `nvidia-driver-<N>`, never `-open` or `-server`) through Ubuntu's
    `ubuntu-drivers` tool, which uses the signed module on Secure Boot systems.
    A reboot is needed to load it. See [`setup/nvidia.sh`](setup/nvidia.sh).

## Configuration

There is no central config block. Each module reads its settings from the
environment and falls back to a sensible default, so most machines need no
configuration at all. Export what you want to override before running:

```bash
JAVA_VERSION="21.0.2-tem"   # pin a Temurin JDK; unset offers a menu
ZSH="$HOME/.oh-my-zsh"      # Oh-My-Zsh install location
SDKMAN_DIR="$HOME/.sdkman"  # SDKMAN install location
COMPOSER_BIN="$HOME/.local/bin/composer"
NPM_PREFIX="$HOME/.local"              # where `npm install -g` puts packages
GIT_USER_NAME="Ada Lovelace"           # non-interactive git identity
GIT_USER_EMAIL="ada@example.com"
GIT_DEFAULT_BRANCH="main"              # name for new repositories
GIT_CORE_EDITOR="code --wait"          # git commit editor; empty leaves it unset
SSH_KEYS_BUNDLE=""                     # optional: install keys from an offline bundle
SSH_KEYS_VERIFY="1"                    # after setup, `ssh -T` each configured host
SSH_DIR="$HOME/.ssh"                   # where step 9 looks for keys / writes config
INSTALL_FIREFOX=""                     # optional: 1 installs, 0 skips, unset prompts (snap-gated)
INSTALL_XBOX=""                        # optional: 1 installs, 0 skips, unset prompts (dongle-gated)
XBOX_DONGLE_IDS=""                     # optional override; empty auto-detects the attached dongle
INSTALL_NVIDIA=""                      # optional: 1 installs, 0 skips, unset prompts (GPU-gated)
NVIDIA_DRIVER=""                       # empty = latest proprietary; a branch (e.g. 580) pins it; "recommended" defers to Ubuntu
SKIP_STEPS=""                          # optional: space-, tab- or comma-separated step ids to skip (e.g. "vscode php nvidia")
SETUP_DESKTOP=""                       # optional: force step 1's desktop (gnome, cinnamon, xfce, mate, kde, lxqt, budgie, unity, unknown)
```

`SKIP_STEPS` lists steps to skip, by their id in the [Status](#status) table.
Interactively it pre-deselects those steps in the checklist; in an unattended run
it is the only selection — every step not listed runs, and step 1 is always
included regardless. A listed id that names no step is warned about and ignored.

`SETUP_DESKTOP` pins step 1's desktop detection instead of the machine's own
session: one of `gnome`, `cinnamon`, `xfce`, `mate`, `kde`, `lxqt`, `budgie`,
`unity`, or `unknown` to skip detection entirely and install only the
desktop-neutral package set. An id that names no desktop is warned about and
detection proceeds normally.

Some settings are arrays edited in place rather than exported — the global
Composer packages in `_COMPOSER_GLOBAL_PACKAGES` in `setup/php.sh` and the
global npm packages in `_NPM_GLOBAL_PACKAGES` in `setup/node.sh`, for example,
which are empty by default. The [preflight](#before-it-runs) has its own switches
(`SETUP_ASSUME_YES`, `SOFT_PREFLIGHT`, `PREFLIGHT_README`).

## After the run

A few changes need a new login to take effect:

1. `exec zsh` (or log out and back in) to pick up the shell and SDKMAN setup.
2. Re-login so the `docker` group membership applies — otherwise `docker` still
   asks for `sudo`.
3. Reboot if an NVIDIA GPU was present — the driver is installed but only loads
   on the next boot. Check it with `nvidia-smi` once you are back in.

## Status

`main.sh` runs the twelve steps below, in order, by default; each can be
deselected at the `Steps to run` prompt (see
[Before it runs](#before-it-runs)) or skipped with `SKIP_STEPS`.

| # | Step | Module |
|---|---|---|
| 1 | System update & base packages | [`setup/base_packages.sh`](setup/base_packages.sh) |
| 2 | Zsh + Oh-My-Zsh | [`setup/zsh.sh`](setup/zsh.sh) |
| 3 | Docker Engine | [`setup/docker.sh`](setup/docker.sh) |
| 4 | Visual Studio Code | [`setup/vscode.sh`](setup/vscode.sh) |
| 5 | Node.js + npm | [`setup/node.sh`](setup/node.sh) |
| 6 | PHP + Composer | [`setup/php.sh`](setup/php.sh) |
| 7 | SDKMAN + Java | [`setup/sdkman.sh`](setup/sdkman.sh) |
| 8 | Git configuration | [`setup/git.sh`](setup/git.sh) |
| 9 | SSH keys | [`setup/ssh.sh`](setup/ssh.sh) |
| 10 | Firefox (optional) | [`setup/firefox.sh`](setup/firefox.sh) |
| 11 | Xbox Wireless Adapter (optional) | [`setup/xbox.sh`](setup/xbox.sh) |
| 12 | NVIDIA drivers (optional) | [`setup/nvidia.sh`](setup/nvidia.sh) |

[`setup/vscode.sh`](setup/vscode.sh) installs Visual Studio Code from
Microsoft's apt repository. It is called from `main.sh` as step 4; deselect it
at the `Steps to run` prompt (or `SKIP_STEPS=vscode`) if a machine should not
get it.

[`setup/php.sh`](setup/php.sh) installs the distribution's own PHP CLI — no
third-party PPA, so the version follows the Ubuntu release (8.1 on 22.04, 8.3 on
24.04, 8.5 on 26.04) — with the common extensions. This is local tooling only:
projects run their own PHP from their Docker setup, so there is no `php-fpm` or
web server here. Composer uses the local-installation flow from
[getcomposer.org](https://getcomposer.org/download/): the installer's SHA-384 is
verified against the signature Composer publishes, and the phar is written to
`~/.local/bin/composer` (no sudo, so Composer's global config stays in your
home). Composer's global bin (`~/.config/composer/vendor/bin`) is appended to
`.zshrc`. Global packages come from the `_COMPOSER_GLOBAL_PACKAGES` array in the
module, empty by default — add an entry such as `'phpunit/phpunit'` and re-run.

[`setup/git.sh`](setup/git.sh) sets the global git identity and a handful of
defaults in `~/.gitconfig`. The identity is only prompted for when it is not
already configured; `GIT_USER_NAME` and `GIT_USER_EMAIL` supply it
non-interactively, and in an unattended run without them the field is left
unset rather than guessed. The default branch is `main` (`GIT_DEFAULT_BRANCH`
overrides it), the module sets `push.default current` plus
`push.autoSetupRemote`, `fetch.prune`, `rebase.autosquash`, `rerere`,
`merge.conflictstyle zdiff3`, `diff.algorithm histogram` and `color.ui auto`,
and points `core.editor` at `code --wait` when VS Code is present.

[`setup/ssh.sh`](setup/ssh.sh) adopts the SSH keys already in `~/.ssh`. An
up-front `ssh_preflight` (see [Before it runs](#before-it-runs)) decides whether
to use a bundle, adopt the keys in `~/.ssh`, or skip before any install work
begins. Since this repository is public and the module never fetches anything,
the keys stay wherever you keep them — a MEGA download, a USB stick — and you
copy them into `~/.ssh` yourself. The module then tightens their permissions and,
for every key that has no host mapping yet, asks which host it belongs to and
writes a `Host` block to `~/.ssh/linux-utils.conf`:

```
Found SSH key id_ed25519_personal — SHA256:…
  ›  Host alias for id_ed25519_personal (blank to skip) github-personal
  ›  HostName for github-personal (blank = github-personal) github.com
  ›  User for github-personal (blank for none) git
```

A blank alias skips a key; without a terminal the prompts answer nothing and the
key is left unmapped rather than guessed at. A key already referenced by an
`IdentityFile` line — whether written here on a previous run or by hand — is
never re-prompted, and only fingerprints are printed, so no key material reaches
the run log. The blocks are pulled into `~/.ssh/config` by a single
`Include linux-utils.conf` line prepended to it, because `ssh_config` is
first-match-wins and the `Host` entries should take precedence over a catch-all;
your own `~/.ssh/config` is otherwise untouched.

Setting `SSH_KEYS_BUNDLE` installs from an offline bundle instead, which is the
reproducible, non-interactive path:

```
ssh-bundle/
├── keys/                 # → ~/.ssh, filenames kept as-is; private 600 / .pub 644
│   ├── id_ed25519_personal
│   ├── id_ed25519_personal.pub
│   └── ...
└── config.d/*.conf       # host blocks, concatenated into ~/.ssh/linux-utils.conf
```

A bundle is a directory, `.tar.gz`, `.tar` or `.zip`; `keys/` is preferred but a
flat folder of key files also works, and a bundle with no `config.d/` leaves the
managed config alone. An existing key is never overwritten — an identical file
is reported and skipped, a differing one is left alone and warned about. Set
`SSH_KEYS_VERIFY=1` to `ssh -T` every concrete host afterwards. See
[`docs/ssh-keys.md`](docs/ssh-keys.md) for the bundle format and worked examples.

[`setup/firefox.sh`](setup/firefox.sh) swaps Ubuntu's Firefox snap for the Mozilla
team's apt build. It acts only when `snap list firefox` finds the snap — Ubuntu's
`1:1snap…` transition package does not count as a real deb, because it is what
pulls the snap in — and it asks first. If a real deb is already installed it only
offers to remove the leftover snap. `INSTALL_FIREFOX=1`
installs without asking, `INSTALL_FIREFOX=0` skips. It removes the snap, purges
the transition package, adds `ppa:mozillateam/ppa`, pins that archive at
priority `1001` so it wins over the Ubuntu archive, records it for unattended
upgrades, and installs `firefox` as a deb. The PPA is probed first and skipped
with a warning if it publishes no suite for the running release, so a dead PPA
cannot abort the run. To undo, reinstall the snap (`sudo snap install firefox`)
and remove `/etc/apt/preferences.d/mozilla-firefox`.

[`setup/xbox.sh`](setup/xbox.sh) is a dual-boot fix rather than an install. On a
Windows + Linux machine, Linux claims the Microsoft Xbox Wireless Adapter on
every boot, which makes Windows ask to re-pair the controller the next time it
starts. The step identifies the dongle in sysfs dynamically: any Microsoft USB
device (`idVendor` `045e`) whose product string names an Xbox adapter, or whose
interface is bound to the `mt76x2u` WiFi driver the dongle uses. An Xbox
controller is never caught, because it binds `xpad`/`xone` and its product string
says "controller". The udev rule is then generated from the `idProduct`(s)
actually present — a revision we have never seen works without a code change, and
wired-only machines report the skip.

When a dongle is found, the step asks before writing a rule that de-authorizes it
the moment it appears (`echo 0 >/sys/$devpath/authorized`), so Linux leaves it
alone and the Windows pairing survives. It is idempotent, reloads the rules with
`udevadm control --reload-rules` and `udevadm trigger`, and needs no reboot.
`INSTALL_XBOX=1` installs without asking and `INSTALL_XBOX=0` skips; because
`INSTALL_XBOX=1` on a machine with no dongle has nothing to derive an ID from,
`XBOX_DONGLE_IDS="02e6 02fe"` supplies the product IDs explicitly (it overrides
detection entirely). The trade-off is that the adapter does not work on Linux
afterwards, so pair the controller once more in Windows after enabling the rule.
To undo it, remove `/etc/udev/rules.d/99-xbox-wireless-adapter.rules` and reload
the rules again.

[`setup/nvidia.sh`](setup/nvidia.sh) is the other hardware-gated step: it
looks for an NVIDIA display controller (PCI vendor `0x10de` with class `0x03xx`,
read from sysfs so it needs nothing installed) and skips with a message on
everything else. When a GPU is found and no driver is loaded or installed, it
asks whether to proceed — `INSTALL_NVIDIA=1` installs without asking,
`INSTALL_NVIDIA=0` skips without asking — then installs `ubuntu-drivers-common`
and runs `ubuntu-drivers install nvidia:<branch>`. The branch is the highest
plain `nvidia-driver-<N>` that `ubuntu-drivers devices` offers: `-open` (NVIDIA
open kernel modules) and `-server` branches are deliberately not chosen. Pin a
branch with `NVIDIA_DRIVER=580`, or set `NVIDIA_DRIVER=recommended` to accept
whatever Ubuntu recommends. The driver only loads on reboot, which is why the
step runs last.

### Known gaps

- `add_custom_repositories` re-adds every PPA and reinstalls the whole base set
  on each run. Harmless — `apt install` on an installed package is a no-op, and
  `add-apt-repository` on an already-added PPA is a no-op — but slower than it
  needs to be, and the only step that is not re-runnable cheaply. The index
  refresh is already batched, though: each `add-apt-repository` runs with `-n`
  where supported, so the seven PPAs (and the `universe`/`multiverse` enable)
  cost one explicit `apt update` instead of nine.
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
├── docs/
│   ├── default-shell.md # why zsh runs second
│   └── ssh-keys.md      # SSH key bundle format and example
├── Dockerfile           # disposable sandbox image for scripts/docker-test.sh
├── .dockerignore
├── main.sh              # entrypoint — owns shell options, logging, preflight
├── lib/
│   ├── ui.sh            # colors, banners, sections, log levels, spinner, markdown
│   ├── log.sh           # the run log file and the `run` command wrapper
│   ├── utils.sh         # command_exists, _sudo, append_if_missing
│   └── preflight.sh     # machine detection, requirement checks, confirmation
├── scripts/
│   ├── build-archive.sh # package the repo into a makeself .run for a release
│   └── docker-test.sh   # run main.sh on a clean Ubuntu in a throwaway container
└── setup/
    ├── base_packages.sh # apt repositories + base packages
    ├── docker.sh        # Docker Engine from the official repo
    ├── firefox.sh       # Firefox as a deb instead of the snap (snap-gated)
    ├── git.sh           # global git identity and defaults
    ├── node.sh          # Node.js + npm from the archive
    ├── nvidia.sh        # NVIDIA proprietary driver via ubuntu-drivers (GPU-gated)
    ├── php.sh           # PHP CLI from the archive + Composer
    ├── zsh.sh           # zsh, Oh-My-Zsh, powerlevel10k, base .zshrc
    ├── vscode.sh        # VS Code from Microsoft's apt repository
    ├── sdkman.sh        # SDKMAN + Temurin JDK
    ├── ssh.sh           # adopt ~/.ssh keys + host config, or an offline bundle
    └── xbox.sh          # de-authorize the Xbox dongle for a Windows dual boot
```

`lib/` holds the reusable pieces, `setup/` holds the steps. `main.sh` is the only
file that runs; everything else is sourced. The split mirrors the split inside
each step: a `setup/*.sh` file sources the libraries it needs from `../lib/`,
following the same pattern the libraries use among themselves. Nothing ties the
libraries to this program, either — see
[Using the libraries in your own scripts](#using-the-libraries-in-your-own-scripts).

## The `lib/` libraries

The libraries are layered by concern, and the split is strict:

> **`lib/*.sh` never calls `exit` and never changes the caller's shell options.**
> Every function returns a status instead. What ends the program — shell
> options, `IFS`, the `ERR` trap, `exit` — belongs to `main.sh`.

That is why `lib/ui.sh` is a pure presentation layer: no `set`, no `trap`, no
log file, no `/etc/os-release`, no markdown parsing, no `exit`.

The tables below are the reference;
[Using the libraries in your own scripts](#using-the-libraries-in-your-own-scripts)
is the guide to consuming them from a script of your own.

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
| `prompt_input "question" [default]` | Free-text prompt on stderr; the entered value on stdout. Policy-free — no TTY or CI handling. |
| `prompt_multiselect "prompt" "required_id" "off_ids" "id\|label" …` | Arrow-key checklist drawn on stderr; the chosen ids on stdout, one per line. Policy-free — no TTY or CI handling. |
| `prompt_select_one "prompt" "default_id" "id\|label" …` | Arrow-key single-choice list drawn on stderr; Enter commits the highlighted row, `q`/Ctrl-D returns 1. The chosen id on stdout. Policy-free — no TTY or CI handling. |
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
| `ask "prompt" [default]` | Free text plus the auto-answer policy: `SETUP_ASSUME_YES=1`, or no TTY, takes `default`; fails when there is no default. |
| `select_steps "prompt" "required_id" "id\|label" …` | `prompt_multiselect` plus the non-interactive policy: `SETUP_ASSUME_YES=1`, or no usable terminal, selects every step minus `SKIP_STEPS`. Returns 1 on an interactive abort (`q`/Ctrl-D), 2 when there is nothing to select from. |
| `select_one "prompt" "default_id" "id\|label" …` | `prompt_select_one` plus the auto-select policy: `SETUP_ASSUME_YES=1`, or no usable terminal, takes `default_id` (first item when the id is unknown). Returns 1 on an interactive abort (`q`/Ctrl-D), 2 when there is nothing to choose from. |
| `readme_section "Heading" [file]` | Print the body of any `## Heading` in a markdown file, stopping at the next heading. |
| `_os_release` | Read a value out of `/etc/os-release`. |
| `detect_desktop_environment` | Print the machine's desktop id (`gnome`, `cinnamon`, `xfce`, `mate`, `kde`, `lxqt`, `budgie`, `unity`), `unknown` when none — or more than one — matches. Order: `SETUP_DESKTOP`, the XDG session variables, the account's saved session, the installed session package. |
| `_normalize_desktop_token` | Map one session token (`X-Cinnamon`, `ubuntu`, `plasmawayland`) to a desktop id; fails when the token names no desktop. |

Each requirement needs a check, registered as a `key|predicate|detail` row in
`_REQ_CHECKS`. The `key` must appear as a whole word in the matching README
bullet, which supplies the label that gets printed — so the README stays the
source of truth for wording and the table only carries machine-specific logic.

| Key | Predicate | Detail |
|---|---|---|
| `linux` | `_req_check_linux` | `kernel <uname -sr>` |
| `bash` | `_req_check_bash` | `bash <version>` |
| `ubuntu` | `_req_check_apt` | `<PRETTY_NAME>, apt: <path>` |
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

## Using the libraries in your own scripts

`lib/` is not internal to this repository. It is four self-contained bash files
with no dependency beyond bash 4 and a terminal, and any script can source them
the way `main.sh` does — which is also the way a `setup/*.sh` step sources them
from `../lib/`. `setup/` is the part that is *not* reusable: those are steps of
this program, not a library.

The layering rule above is what makes that safe to do. The libraries never call
`exit` and never touch your shell options, so everything that decides whether
the program stops stays in the script that sources them.

### Getting the files

Clone this repository (or add it as a submodule) and point at `lib/` — or copy
the directory into your own project and treat it as vendored code, which is
four files of plain bash with nothing third-party in them. Either way nothing
resolves against the working directory: every file finds its siblings from
`BASH_SOURCE`, and the `readonly` load guards make a repeated `source` a no-op.

| Source | Also loads | Provides |
|---|---|---|
| `lib/ui.sh` | — | `banner`, `section`, `info` / `warn` / `error` / `success` / `step`, the spinner, `bullet`, `md_inline`, and the `prompt_*` family |
| `lib/utils.sh` | — | `command_exists`, `_sudo`, `append_if_missing` |
| `lib/log.sh` | `ui.sh` | `run`, `log_tail`, `LOG_FILE` |
| `lib/preflight.sh` | `ui.sh`, `utils.sh` | `preflight`, `show_requirements`, `check_requirements`, `confirm`, `choose`, `ask`, `select_steps`, `select_one`, `readme_section`, `_os_release` |

`log.sh` and `preflight.sh` between them load everything else, so those two plus
`utils.sh` are the whole surface:

```bash
__lib="${LINUX_UTILS_LIB:-$HOME/code/linux-utils/lib}"
source "$__lib/log.sh"        # ui.sh comes with it
source "$__lib/utils.sh"
source "$__lib/preflight.sh"  # ui.sh and utils.sh again — guarded
```

### What your script owns

The libraries return a status and stop there. Four things belong to the script
that sources them:

1. **Shell options and `IFS`.** `set -eEuo pipefail` and `IFS=$'\n\t'`, set by
   your script and not by a sourced file — `set -e` inside a sourced file does
   not reliably enable errexit. The libraries are written and tested under
   exactly that combination.
2. **The traps.** `trap spinner_cleanup EXIT`, so an aborted run cannot leave a
   disowned spinner redrawing over the shell prompt; plus an `ERR` trap if you
   want a failure reported with the file and line — [`main.sh`](main.sh) shows
   the shape, including the `BASH_SUBSHELL` guard.
3. **`run_or_die`.** `run` in `lib/log.sh` only *returns* the command's status,
   and `lib/` never exits, so the fatal version is the entrypoint's own
   one-liner: `run_or_die() { run "$@" || exit $?; }`. Copy it, or write your
   own policy over `run`.
4. **The log file.** `run` appends raw command output to `$LOG_FILE`, and that
   output can contain secrets. Export `LOG_FILE` before sourcing to choose the
   path, then create it and `chmod 600` it — `main.sh` does both.

Notice what is absent: nothing in `lib/` runs `preflight` for you, and nothing
there exits. `preflight` returns 1 when a requirement failed and 130 when the
user declined; `confirm` returns 1 for "no". Acting on those is your call.

### A complete example

```bash
#!/usr/bin/env bash
# my-setup — a standalone script built on linux-utils/lib
set -eEuo pipefail
IFS=$'\n\t'

__lib="${LINUX_UTILS_LIB:-$HOME/code/linux-utils/lib}"
source "$__lib/log.sh"
source "$__lib/utils.sh"
source "$__lib/preflight.sh"

# `run` appends raw command output here, and that output can contain secrets.
: >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true
trap spinner_cleanup EXIT

run_or_die() { run "$@" || exit $?; }   # the entrypoint's one-liner

install_something() {
    _sudo apt-get install -y something
}

banner 'MY SETUP'

# Shows the ## Requirements bullets, proves them against this machine, asks to
# go ahead. The file is PREFLIGHT_README, or a clone's README.md by default.
preflight || exit $?

if confirm 'Install something?'; then
    run_or_die 'Installing something' install_something
else
    warn 'Skipped — nothing installed'
fi

# The idempotency primitive for dotfiles: appended only when the marker is
# not already present.
append_if_missing "$HOME/.zshrc" 'export PATH="$HOME/.local/bin:$PATH"' \
    'export PATH="$HOME/.local/bin:$PATH"'
info "Done — log: $LOG_FILE"
```

The conventions from [Writing a new module](#writing-a-new-module) carry over
where they still hold — no shell options inside a sourced file, `run_or_die`
for anything whose failure should end the run, four-space indent. What changes
is who owns the decisions: a module is called by `main.sh`, which has already
set the shell options, installed the traps and run `preflight`, while a script
like the one above has to do all three itself.

### Which prompt to call

Every prompt in `ui.sh` is policy-free: it always reads the terminal. The
wrappers in `preflight.sh` add the non-interactive policy on top — with
`SETUP_ASSUME_YES=1`, or with no terminal on stdin, they answer for you:

| You want | Call | With no TTY or `SETUP_ASSUME_YES=1` |
|---|---|---|
| a question the user must answer | `prompt_yes_no`, `prompt_choice`, `prompt_input`, `prompt_multiselect`, `prompt_select_one` | nothing — it reads stdin, which is at EOF, so the prompt fails (`prompt_multiselect` returns its current selection) |
| a question that has a sensible default | `confirm`, `choose`, `ask`, `select_one`, `select_steps` | auto-approved, or the default taken |

`select_one` and `select_steps` ask for stderr as well as stdin — the menu is
drawn there, so a redirected stderr (`main.sh 2>log`) would wait for keys
nobody can see. They note that and take the default instead; the same happens
when `TERM` cannot draw the menu or the window is smaller than 6 rows by 15
columns.

The value always comes back on **stdout** while everything drawn goes to
**stderr**, so a caller captures the answer with `$(...)` and still sees the
menu:

```bash
host="$(ask 'Hostname?' 'dev-box')" || true
profile="$(select_one 'Which profile?' dev prod staging)" || exit 1
```

`select_steps` additionally honours `SKIP_STEPS`, and the notes the
non-interactive wrappers print go to stderr, so they never end up inside a
capture.

### Environment

| Variable | Effect |
|---|---|
| `LOG_FILE` | Where `run` appends output. Defaults to `/tmp/setup-YYYYMMDD-HHMMSS.log`; export it *before* sourcing to override. |
| `SETUP_ASSUME_YES=1` | Auto-approve `confirm` / `choose` / `ask` / `select_*`. Implied automatically when stdin is not a terminal. |
| `SOFT_PREFLIGHT=1` | Report failed requirement checks as warnings and carry on instead of aborting. |
| `PREFLIGHT_README` | The markdown file `preflight` reads: a clone's `README.md` one level above `lib/` by default. The legacy `UI_README` name is still honoured. |
| `SKIP_STEPS` | Space-, tab- or comma-separated ids for `select_steps` to pre-deselect interactively, or to drop entirely in an unattended run. |
| `SETUP_DESKTOP` | Pin step 1's desktop detection to a fixed id (`gnome`, `cinnamon`, `xfce`, `mate`, `kde`, `lxqt`, `budgie`, `unity`; `unknown` = desktop-neutral set only, no detection). An id that names no desktop warns and detection proceeds normally. |

### Gotchas

- **The names are generic.** `info`, `warn`, `error`, `section`, `banner`,
  `run`, `confirm`, `ask`, `choose` — a collision with your own functions is
  settled by source order, so source the libraries first and keep yours.
- **A library loads once per process.** The guards are `readonly`, so a file
  cannot be unloaded and re-sourced; sourcing it twice is simply a no-op.
- **`run` hides the output.** A success prints only the label, the raw output
  goes to `$LOG_FILE`, and the tail of it is printed when the command fails.
- **The spinner is a no-op without a TTY** (see [Notes](#notes)), so piping a
  script built on these libraries is safe rather than garbled.
- **`preflight` wants a markdown file with a `## Requirements` section.** A
  copied `lib/` has no README beside it — pass one (`preflight ./README.md`) or
  set `PREFLIGHT_README`.
- **Reach for `_sudo` instead of `sudo`** when the script may run as root: it
  skips itself there, refreshes the credential once, and pauses a running
  spinner around the password prompt so the prompt is not erased.

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
  ✓  Ubuntu or an Ubuntu derivative, apt based — Ubuntu 24.04.1 LTS, apt: /usr/bin/apt
  ✓  sudo available — the script will prompt for your password — sudo: /usr/bin/sudo
  ✓  All requirements satisfied
  ›  Run the setup now?
  [Y/n]
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
| `SETUP_ASSUME_YES=1` | Skip the `[Y/n]` prompt. Implied automatically when stdin is not a TTY (CI, pipes). |
| `SOFT_PREFLIGHT=1` | Report failed checks as warnings and continue instead of aborting. |

The legacy `UI_README` name is still honoured alongside it. This matters if you
edit the [Requirements](#requirements) bullets: the preflight reads the wording
from there at run time, so a typo in that section shows up on your terminal as
a mismatched or unverified check.

### Choosing steps

Right after the run confirmation, `main.sh` shows the steps it can run as a live
checklist and lets you pick which to run:

```
▶  Steps to run
────────────────────────────────────────────────────────────
  ▶  [x]   1. System update & base packages  (required)
     [x]   2. Zsh + Oh-My-Zsh
     [x]   3. Docker Engine
     ...
     [x]  12. NVIDIA drivers (GPU-gated)

     ↑/↓ move · space toggle · a all · n none · Enter continue · q quit
```

Everything starts selected. `↑`/`↓` (or `j`/`k`) move the cursor, `space` toggles
the highlighted step, `a` selects all, `n` deselects every step except the
required first one, `Enter` confirms and `q` or `Ctrl-D` aborts the run. Step 1
(system update & base packages) is the bootstrap the later steps depend on, so
it is always selected — the cursor can land on it, but `space` there is
rejected. A deselected step prints a `Skipping: …` line and is otherwise
untouched; the three already-gated steps (firefox, xbox, nvidia) keep their own
hardware checks and prompts when they are selected. The checklist sizes itself to the terminal: every line is clipped to
the window width (a wrapped line would scramble the redraw), and on a window
too short for all twelve rows it shows the rows around the cursor rather than
the whole list.

In a non-interactive run the choice comes from `SKIP_STEPS` (see
[Configuration](#configuration)): with no terminal, or with
`SETUP_ASSUME_YES=1`, every step except those listed runs. The same list also
pre-deselects those steps in the interactive checklist. The checklist needs a
terminal to draw *on* as well as one to read from — stderr for the menu, stdin
for the keys, a `TERM` that can render it, and a window of at least 6 rows by
15 columns — so `main.sh 2>log`, a dumb/unset `TERM`, or a window too small for
the list falls back to that same non-interactive path, saying so first instead
of waiting for keys nobody can see.

Skipping `zsh` does not drop `~/.local/bin` from PATH: step 1 puts it in
`~/.profile`, which bash login shells read (Ubuntu's stock `.profile` already
has it), while the zsh step's own copy in `.zshrc` simply does not happen. If
your login shell is zsh even though you skipped the step, add
`export PATH="$HOME/.local/bin:$PATH"` to your own zsh config — zsh does not
read `~/.profile`.

### SSH keys up front

Immediately after the run confirmation, `main.sh` shows the `Steps to run`
checklist (see [Choosing steps](#choosing-steps)); once that selection is made
— and only when the SSH step itself stays selected — it calls `ssh_preflight`,
so the SSH decision is made before anything is installed. It looks for a
bundle, then for private keys in `~/.ssh`, and asks whether to use what it
finds:

```
▶  SSH keys
────────────────────────────────────────────────────────────
  ✓  Found 2 SSH key(s) in /home/you/.ssh
  ›  id_ed25519_personal, id_ed25519_work
  ›  Set up SSH keys from ~/.ssh now?
  [Y/n]
```

With neither a bundle nor keys it reports that SSH setup will be skipped for now
and carries on with the rest of the run:

```
▶  SSH keys
────────────────────────────────────────────────────────────
  !  No SSH keys in /home/you/.ssh and SSH_KEYS_BUNDLE is not set
  ›  SSH setup will be skipped for now
```

The answer is remembered as a plan and step 9 carries it out, so SSH is decided
once, up front, and never re-prompted. Detection here is dependency-free (it
reads key headers rather than calling `ssh-keygen`), because it runs before step 1
has installed `openssh-client`. Like every other confirmation, it is
auto-approved by `SETUP_ASSUME_YES=1` or with no terminal.

### Unattended runs

Two things must be true for `main.sh` to run with no terminal:

- `SETUP_ASSUME_YES=1` (implied automatically when stdin is not a TTY) so the
  confirmation is skipped.
- The invoking user is `root`, or has passwordless `sudo`. When a TTY is
  present the script caches `sudo` credentials once; an unattended run cannot
  answer a password prompt, so `sudo` must not ask.

With no terminal every step runs, exactly as a clean clone always has. Set
`SKIP_STEPS` to skip steps unattended — `SKIP_STEPS="vscode php nvidia"` — rather
than maintaining a fork with the `*_setup` calls removed.

Non-interactive apt is handled for you: the entrypoint exports
`DEBIAN_FRONTEND=noninteractive`, `NEEDRESTART_MODE=a` and
`APT_LISTCHANGES_FRONTEND=none`, and pre-accepts the core-fonts EULA that
`ubuntu-restricted-extras` pulls in. The base package set is split into a small
core (missing → the run stops), desktop-neutral extras (missing → warned about
and skipped) and desktop-specific extras picked from the detected desktop —
which `SETUP_DESKTOP` pins unattended: `SETUP_DESKTOP=gnome`, or
`SETUP_DESKTOP=unknown` for the neutral set with no detection at all. That is
what makes the same script work across 22.04, 24.04 and 26.04, where packages
come and go — for example `fastfetch` is absent before 24.04, and a PPA that
publishes no suite for the release is skipped rather than failing the run.

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

Then source it from `main.sh` alongside the other libraries, add an
`id|label` entry to `_STEP_SPECS` there, and add a `run_step id` section in the
run order. The registry is what puts the step in the `Steps to run` checklist.

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
- **A new file needs three edits:** a `source` line in `main.sh`, a `_STEP_SPECS`
  registry entry (and a `run_step` call), and an entry in `REQUIRED_FILES` in
  `scripts/build-archive.sh`. The archive payload is an allowlist, so a module
  that is not listed works from a clone and is silently missing from a release.
- **Indent is 4 spaces, no tabs,** in every `.sh` file — one level per block,
  including the payload of a `bash -c '…'` string. Here-doc bodies start at
  column 0, because `<<EOF` strips the indentation but not the content.

## Notes

- **Docker group:** `usermod -aG docker "$(id -un)"` grants root-equivalent access.
  Only do this on a machine you fully trust. `id -un` rather than `$USER` because
  `$USER` is unset under `env -i`, which is fatal with `set -u`.
- **Third-party PPAs:** `setup/base_packages.sh` adds seven personal package
  archives (LibreOffice, Solaar, mpv, deadbeef, gnome-mpv, grub-customizer, GDM
  settings) and installs packages straight out of them, so dropping the
  `add-apt-repository` lines means also dropping the packages that only exist
  there. Two of the seven are gated: `gnome-mpv` is probed only on a GTK
  desktop, where the `celluloid` package it builds belongs, and `gdm-settings`
  only when the detected desktop is GNOME *and* GDM is the active display
  manager (`/etc/X11/default-display-manager`) — any other machine never
  probes, let alone adds, them. `setup/php.sh` deliberately does not add a PHP
  PPA: it installs the distribution's own PHP, so the version tracks the Ubuntu
  release rather than upstream.
- **A PPA without a suite for your Ubuntu is skipped, never fatal.** `apt update`
  exits 100 on any configured repository it cannot fetch, so one dead PPA would
  otherwise abort the whole run at step 1 — which is exactly what
  `ppa:ubuntuhandbook1/mpv` did on Ubuntu 26.04, having published nothing for
  `resolute`. Each PPA is probed with a `HEAD` request against its `Release` file
  first, and skipped with a warning if there is no suite for
  `$VERSION_CODENAME`. Don't "simplify" this back to bare `add-apt-repository`
  lines; it will break again on the next Ubuntu release.
- **Node.js, like PHP, comes from the archive — no PPA and no nvm.** The
  version therefore tracks the Ubuntu release rather than upstream, which is an
  accepted trade-off: local Node is a utility for one-off tooling while projects
  run their own version from their Docker image. The consequence is that 22.04
  (Node 12) and 24.04 (Node 18) are past end-of-life, so `setup/node.sh` warns
  when the installed major is below 20 and installs anyway. `npm` is a separate
  archive package because Ubuntu builds `nodejs` `--without-npm`; it is also what
  provides `npx`. Global packages install into `~/.local` (`NPM_PREFIX`), never
  with sudo.
- **The NVIDIA driver step is GPU-gated and opt-in.** `setup/nvidia.sh` installs
  the newest plain `nvidia-driver-<N>` the hardware supports, not the `-open`
  branch Canonical tends to recommend for Turing and newer. The trade-off: a new
  branch can drop support for older cards, so `NVIDIA_DRIVER=580` pins one that
  still does, and `NVIDIA_DRIVER=recommended` hands the choice back to Ubuntu.
  On a Secure Boot machine, `ubuntu-drivers` installs the signed prebuilt module
  when one exists; a branch that is only available as DKMS may ask to enrol a key
  at the next boot, not during the run.
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
