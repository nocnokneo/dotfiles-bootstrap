# dotfiles-bootstrap

The public entry point to a private dotfiles repo.

```sh
sh -c "$(curl -fsSL https://nocnokneo.github.io/dotfiles-bootstrap/install.sh)"
```

## Why this repo exists

[nocnokneo/dotfiles](https://github.com/nocnokneo/dotfiles) is private, and it is what installs `gh`.
A fresh machine therefore cannot clone it: no `gh`, no credential helper, no clone.

Nothing else in that chain is private.
mise, `gh` and chezmoi are all public downloads, so the fix is to fetch `gh` from its public source, authenticate once, and only then clone.
This script is the two minutes of setup that has to happen before `chezmoi init --apply` can work.

It is deliberately the *only* thing here.
Keeping it in a separate public repo rather than publishing Pages from the private one means no workflow change can ever leak a dotfile: there is nothing private in this repo to leak.

## What it does

1. Installs mise to `~/.local/bin` (`winget` on Windows, where `https://mise.run` is POSIX-only).
2. Installs `gh` through mise.
3. Runs `gh auth login --git-protocol ssh`, which also offers to generate an SSH key and upload it to your account.
4. Installs chezmoi to `~/.local/bin`.
5. Hands off to `chezmoi init --apply nocnokneo/dotfiles`.

Idempotent.
Every step is skipped if it is already done, so re-running it on a provisioned machine is a no-op.

Set `DOTFILES_REPO` to point it somewhere else.

## Two things that are easy to get wrong

**Use `sh -c "$(curl ...)"`, not `curl ... | sh`.**
Piping to `sh` hands the script to `sh` on stdin, so `gh auth login` has no terminal to prompt on and reads the rest of the script as keystrokes.
The script reopens `/dev/tty` when it can and refuses to run when it cannot, so the failure is a clear message rather than a hang.

**The GitHub credential is never written to `~/.gitconfig`.**
chezmoi owns that file and renders its own `gh auth git-credential` helper on apply, so anything written here -- which is all `gh auth setup-git` does -- would be overwritten seconds later.
The helper is passed to the one clone that needs it through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` instead, which git inherits into every child process and which leaves nothing on disk.

## Hosting

GitHub Pages, deployed from the default branch root, so there is no build step and no deploy workflow to fail.
`.nojekyll` makes Pages serve `install.sh` verbatim.

To move this to a custom domain later, add a `CNAME` file and update `BOOTSTRAP_URL` in `install.sh` -- it appears in the error message the TTY guard prints, and nowhere else.
