#!/bin/sh
# Bootstrap a new machine from a PRIVATE dotfiles repo.
#
# Every URL this fetches -- mise, gh, chezmoi -- is public. That is the whole
# point: the dotfiles repo is the only private link in the chain, so this script
# runs before any GitHub credential exists and installs just enough to create
# one. Everything after that is `chezmoi init --apply`, unchanged.
#
# Run it as:
#     sh -c "$(curl -fsSL https://nocnokneo.github.io/dotfiles-bootstrap/install.sh)"
#
# NOT `curl ... | sh`. Piping consumes stdin, so `gh auth login` would read the
# rest of this script as keystrokes instead of prompting. See the TTY guard.
#
# Idempotent -- run it again any time.
set -eu

DOTFILES_REPO="${DOTFILES_REPO:-nocnokneo/dotfiles}"
BOOTSTRAP_URL="https://nocnokneo.github.io/dotfiles-bootstrap/install.sh"
BIN_DIR="${HOME}/.local/bin"

die() {
	printf 'bootstrap: %s\n' "$*" >&2
	exit 1
}

step() { printf '\n==> %s\n' "$*" >&2; }

# `gh auth login` prompts, and so does chezmoi for name and email. Reopen the
# terminal when stdin is a pipe; refuse to run blind when there is none.
# Probe by opening it, not with `[ -c /dev/tty ]`: the device node exists even
# in a process with no controlling terminal, where the open fails with "no such
# device or address" and takes the whole script down with a raw shell error.
if [ ! -t 0 ]; then
	(: </dev/tty) 2>/dev/null || die "no terminal on stdin. Run it as:
    sh -c \"\$(curl -fsSL ${BOOTSTRAP_URL})\""
	exec </dev/tty
fi

if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -qO- "$1"; }
else
	die "need curl or wget"
fi

# A hard requirement, not a convenience: chezmoi's useBuiltinGit defaults to
# "auto", so it shells out to system git whenever git is on PATH -- and only the
# real git consults the credential helper exported at the end of this script.
# With no git found, chezmoi's built-in git clones without credentials and the
# private repo fails.
command -v git >/dev/null 2>&1 || die "git is required; install it and re-run"

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) os=windows ;;
*) os=posix ;;
esac

step "mise"
# Test the file, not the lookup: ~/.local/bin is not on PATH yet on a fresh
# machine, and winget records its shim directory in the registry, so a shell
# started before the install never sees either.
mise="$(command -v mise 2>/dev/null || true)"
if [ -z "$mise" ]; then
	if [ "$os" = windows ]; then
		links="${LOCALAPPDATA:-${HOME}/AppData/Local}/Microsoft/WinGet/Links"
		# $LOCALAPPDATA is a native path; PATH tests here are POSIX.
		if command -v cygpath >/dev/null 2>&1; then
			links="$(cygpath -u "$links")"
		fi
		mise="${links}/mise.exe"
	else
		mise="${BIN_DIR}/mise"
	fi
fi

if [ ! -x "$mise" ]; then
	echo "installing mise to ${mise}"
	if [ "$os" = windows ]; then
		# https://mise.run is POSIX-only and hard-errors "unsupported OS:
		# MINGW64_NT-..." under Git Bash. --scope user keeps everything under
		# %LOCALAPPDATA%, so nothing prompts for elevation.
		command -v winget >/dev/null 2>&1 ||
			die "winget not found -- install App Installer from the Microsoft Store"
		# Judge by the file, not the exit code: winget reports several harmless
		# states (already installed, no applicable upgrade) as a failure.
		winget install --exact --id jdx.mise --source winget --scope user --silent \
			--disable-interactivity --accept-source-agreements --accept-package-agreements || true
		[ -x "$mise" ] || die "winget left no mise at ${mise}"
	else
		MISE_INSTALL_PATH="$mise" sh -c "$(fetch https://mise.run)" ||
			die "could not install mise -- see https://mise.jdx.dev"
	fi
fi

step "gh"
# Writes `gh = "latest"` into the global mise config -- the same line
# dot_config/mise/config.toml.tmpl renders, so the apply at the end of this
# script replaces this file with a superset and nothing is lost.
"$mise" use --global gh@latest

# The real binary, not the shim. Shims resolve through mise's config lookup,
# which is not yet in its final state here, and they fail outright under a
# non-default $HOME.
gh="$("$mise" which gh)"
if [ "$os" = windows ] && command -v cygpath >/dev/null 2>&1; then
	gh="$(cygpath -u "$gh")"
fi

step "GitHub authentication"
if "$gh" auth status --hostname github.com >/dev/null 2>&1; then
	echo "already logged in as $("$gh" api user --jq .login)"
else
	# --git-protocol ssh so gh offers to generate a key and upload it to the
	# account. That key is what later makes `dotfiles.repository` work in a
	# local dev container: VS Code forwards the SSH agent into the container,
	# which has no GitHub token of its own.
	#
	# The credential method stays interactive on purpose. The browser flow is
	# right on a laptop, the device code is right over bare SSH, and pasting a
	# token is the only option on a machine that can reach neither.
	"$gh" auth login --hostname github.com --git-protocol ssh
fi

step "chezmoi"
chezmoi="$(command -v chezmoi 2>/dev/null || true)"
if [ -z "$chezmoi" ]; then
	if [ "$os" = windows ]; then
		chezmoi="${BIN_DIR}/chezmoi.exe"
	else
		chezmoi="${BIN_DIR}/chezmoi"
	fi
fi
if [ ! -x "$chezmoi" ]; then
	echo "installing chezmoi to ${chezmoi}"
	sh -c "$(fetch https://get.chezmoi.io)" -- -b "$(dirname "$chezmoi")" ||
		die "could not install chezmoi -- see https://www.chezmoi.io"
fi

step "dotfiles"
# The credential helper goes in the ENVIRONMENT, never in ~/.gitconfig. chezmoi
# owns that file and renders its own gh helper on apply, so writing one here --
# which is all `gh auth setup-git` does -- would be overwritten seconds later.
# git passes GIT_CONFIG_* down to every child process and chezmoi shells out to
# system git, so the clone authenticates and nothing is left on disk.
#
# HTTPS rather than the SSH remote `gh repo clone` would pick: it needs no port
# 22 and no host-key prompt on a machine that has never contacted github.com.
# The managed ~/.gitconfig serves this remote afterwards, so `chezmoi update`
# keeps working with no further setup.
#
# The absolute path to gh is safe only because it dies with this process. It
# points into mise's VERSIONED install directory, which the next
# `mise upgrade gh` invalidates -- which is why the managed ~/.gitconfig
# resolves gh on PATH instead.
GIT_CONFIG_COUNT=1 \
	GIT_CONFIG_KEY_0="credential.https://github.com.helper" \
	GIT_CONFIG_VALUE_0="!'${gh}' auth git-credential" \
	exec "$chezmoi" init --apply "$DOTFILES_REPO"
