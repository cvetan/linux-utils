# Default shell, and why zsh runs second

Notes from a discussion about the shell the setup runs under and the order of the
steps in `main.sh`.

## What changed

`zsh_setup` moved from step 3 to step 2, immediately after base packages, and
`docker_setup` dropped to step 3. The numbered sections in [`main.sh`](../main.sh)
and the list and Status table in the [`README`](../README.md) were updated to
match.

```
1. base_packages_setup
2. zsh_setup        # was 3
3. docker_setup     # was 2
4. vscode_setup
6. php_setup
7. sdkman_setup
8. git_setup
```

## Why

Language and tool installers write an init block into the user's shell config.
That config has to exist before they run, so zsh is set up before Docker and the
rest of the installers. zsh already ran before SDKMAN in the old order; moving it
to step 2 also puts it ahead of Docker.

## The catch: the default shell vs `$SHELL` during the run

Changing the login shell and changing the shell a process runs under are two
different things.

- `zsh_setup` calls `chsh -s <zsh> <user>`, which only takes effect at the
  **next login**. It does not change the shell this script is currently running
  under.
- Throughout the run, `main.sh` is still executing under `bash`, and `$SHELL` in
  the environment still points at bash. Exporting `SHELL` at the top of the run
  and running `chsh` mid-script do not change either fact for the already-running
  process.

So an installer that inspects `$SHELL` — or simply checks which rc files exist —
to decide where to write its init can still land its block in `.bashrc` even
though zsh is (or will be) the default login shell.

## How SDKMAN is covered today

`setup/sdkman.sh` does not rely on the installer getting this right. Its
`extend_zshrc` function appends the SDKMAN init block to `.zshrc` idempotently,
keyed on the `SDKMAN_DIR` marker:

```sh
append_if_missing "$HOME/.zshrc" 'SDKMAN_DIR' "$block"
```

The comment above it notes the installer may have already appended its own block
and that the marker makes the append a no-op in that case — otherwise it is the
safety net. Because `zsh.sh` writes the base `.zshrc` first, the SDKMAN block
lands after the "User configuration" section rather than being overwritten.

## Options if installers must target zsh explicitly

1. **Export `SHELL` before the installer steps.** Point `SHELL` at the zsh
   binary (`command -v zsh`) so tools that branch on `$SHELL` choose the zsh
   path. This does not change the shell the script runs in, only what a child
   process sees.
2. **Run the installer body under zsh.** Invoke it as `zsh -c '…'` (or `env
   SHELL=/bin/zsh …`) so the installer's own shell detection runs inside zsh.
3. **Keep the per-module safety net.** Continue appending the needed block to
   `.zshrc` in the module that owns it, as `setup/sdkman.sh` does. This is the
   most robust option because it does not depend on the installer's detection at
   all.

Nothing in the current modules depends on option 1 or 2 yet; the SDKMAN module
already uses option 3.
