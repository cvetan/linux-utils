# SSH keys and host config

Notes on how [`setup/ssh.sh`](../setup/ssh.sh) handles your SSH keys. This is
step 9 of [`main.sh`](../main.sh).

## The up-front check

The SSH decision is made before anything is installed. Right after the run
confirmation, `main.sh` calls `ssh_preflight`, which reports what it found and
records a plan in `_SSH_MODE`; step 9 (`ssh_setup`) then executes that plan, so
you are asked once and never re-prompted. Precedence is bundle first, then keys
in `~/.ssh`, then skip.

```
▶  SSH keys
────────────────────────────────────────────────────────────
  ✓  Found 2 SSH key(s) in /home/you/.ssh
  ›  id_ed25519_personal, id_ed25519_work
  ›  Set up SSH keys from ~/.ssh now? [Y/n]
```

```
▶  SSH keys
────────────────────────────────────────────────────────────
  !  No SSH keys in /home/you/.ssh and SSH_KEYS_BUNDLE is not set
  ›  SSH setup will be skipped for now
```

A declined prompt, or a `SSH_KEYS_BUNDLE` that points at nothing, also ends in
"skipped for now". Detection here is deliberately dependency-free — it looks for
a private-key header (or a matching `.pub`) instead of calling `ssh-keygen`,
because it runs before step 1 has installed `openssh-client`. The prompts use
[`confirm`](../lib/preflight.sh), so `SETUP_ASSUME_YES=1` or a non-terminal
auto-approves and an unattended run neither hangs nor writes guessed config.

## The default path: adopt what is already in `~/.ssh`

The repository is public and the module never fetches anything, so keys stay
wherever you keep them. Copy them into `~/.ssh` however you like — from MEGA, a
USB stick, `scp` — and the step adopts them:

1. every private key it finds is tightened to `600` and its fingerprint printed;
2. for each key with no host mapping yet, it asks which host the key is for and
   writes a `Host` block.

```
Found SSH key id_ed25519_personal — SHA256:…
  ›  Host alias for id_ed25519_personal (blank to skip) github-personal
  ›  HostName for github-personal (blank = github-personal) github.com
  ›  User for github-personal (blank for none) git
```

The resulting `~/.ssh/linux-utils.conf`:

```
# ---- id_ed25519_personal (linux-utils) ----
Host github-personal
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal
    IdentitiesOnly yes
```

With that in place, `git@github-personal:you/repo.git` uses the personal key.
A blank alias skips a key; a blank `HostName` omits the line (so a `Host` that is
already a real hostname, like `github.com`, needs nothing but the alias); a blank
`User` omits that line too.

### Idempotency

A key is only prompted for if its basename does not appear in an `IdentityFile`
line already — in `linux-utils.conf` or in your own `~/.ssh/config`. So a re-run
is quiet, and a mapping you wrote by hand is honoured and never re-prompted. New
keys dropped into `~/.ssh` later are picked up and asked about on the next run.

### No terminal

The prompts use [`ask`](../lib/preflight.sh), whose non-interactive policy is to
take the default and, with no default, answer nothing. The alias prompt has no
default, so an unattended run leaves keys unmapped (with a warning) rather than
writing guessed config. Nothing hangs.

## Optional: install from an offline bundle

For a reproducible, non-interactive restore, export `SSH_KEYS_BUNDLE` instead and
the module installs the keys from a bundle you prepared. A bundle is a directory,
a `.tar.gz`, a `.tar` or a `.zip`:

```
ssh-bundle/
├── keys/                     # → ~/.ssh, filenames kept as-is
│   ├── id_ed25519_personal
│   ├── id_ed25519_personal.pub
│   ├── id_ed25519_work
│   └── id_ed25519_work.pub
└── config.d/
    ├── github-personal.conf
    └── github-work.conf
```

- **`keys/`** is copied into `~/.ssh`, private keys `600`, public keys `644`. It
  is preferred; if there is none, the top level of the bundle is used, so a flat
  folder of key files also works.
- **`config.d/*.conf`** are concatenated, in name order, into
  `~/.ssh/linux-utils.conf` (rewritten on every run, so edits propagate). A
  bundle with no `config.d/` leaves the managed config alone.

```bash
SSH_KEYS_BUNDLE="$HOME/Downloads/ssh-bundle.tar.gz" ./main.sh
```

## What it does to `~/.ssh/config`

Your own `~/.ssh/config` is never rewritten. The module adds a single line —
prepended, because `ssh_config` is first-match-wins and the managed `Host` blocks
should win over a catch-all you may have — and leaves the rest alone:

```
# Managed by linux-utils (ssh host config)
Include linux-utils.conf

# ...your existing configuration...
```

`Include` resolves relative paths against `~/.ssh`, so the line is portable. The
`Include` and its marker are written at most once, and only when there is
something in the managed file.

## Safety

- **Keys are never overwritten.** The adopt path never writes key material at
  all; the bundle path only copies, and refuses to clobber — an identical file is
  reported and skipped, a differing one is left in place and warned about.
- **No key material reaches the log.** `lib/log.sh`'s `run` appends a command's
  output to the run log, so keys are only ever `chmod`'ed or copied with
  `install` (which prints nothing), and only `ssh-keygen -lf` fingerprints are
  printed.
- **Encrypted keys are recognised without their passphrase.** Detection uses
  `ssh-keygen -lf`, which reads the public half embedded in an OpenSSH private
  key, so an encrypted key is adopted without hanging on a passphrase prompt.
- **Temporary bundle extractions are private.** An archive is unpacked into a
  `700` temp directory and removed when the step finishes.

## Variables

| Variable | Effect |
|---|---|
| `SSH_KEYS_BUNDLE` | Optional. When set, install keys from this directory/`.tar`/`.tar.gz`/`.zip` instead of adopting `~/.ssh`. |
| `SSH_KEYS_VERIFY` | `1` runs `ssh -o BatchMode=yes -T` against every concrete `Host` in the managed config. Non-fatal: the provider's banner is reported, and the exit status is ignored because it is provider-specific (GitHub exits `1` after a successful authentication). |
| `SSH_DIR` | Directory to adopt from and write config to, `$HOME/.ssh` by default. Mainly for testing. |
