#!/usr/bin/env bash
# Copy lazy-lock.json from the Neovim configuration in daily use into this
# working copy, so that a plugin set proven by daily use can be reviewed here
# and committed once it is trusted.
#
# The configuration in daily use (~/.config/nvim, a checkout of this repository
# deployed by `icon neovim -c`) is where :Lazy update writes lazy-lock.json.
# This script only copies that file; committing and pushing it stays manual and
# deliberate.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dst=$repo_dir/lazy-lock.json
src=${NVIM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nvim}/lazy-lock.json

if [[ ! -f $src ]]; then
    echo "The lock file $src of the Neovim configuration in daily use does not exist." >&2
    exit 1
fi

if [[ $src -ef $dst ]]; then
    echo "$src and $dst are the same file, so there is nothing to copy."
    exit 0
fi

if diff -q "$dst" "$src" >/dev/null 2>&1; then
    echo "$dst is already identical to $src."
    exit 0
fi

# The age of the lock file in daily use is how long the plugin set it pins has
# been exercised, which is the signal for whether it is trusted yet.
mtime=$(stat -c %Y "$src" 2>/dev/null || stat -f %m "$src")
days=$((($(date +%s) - mtime) / 86400))
echo "The lock file in daily use was last updated $days day(s) ago."
echo

diff -u "$dst" "$src" || true
echo

read -r -p "Copy the above lock file into $repo_dir? [y/N] " reply
if [[ ! $reply =~ ^[Yy]$ ]]; then
    echo "Nothing is copied."
    exit 0
fi

cp "$src" "$dst"
echo "The lock file has been copied into $dst."
echo "Review it, and then commit and push it to share the plugin set."
