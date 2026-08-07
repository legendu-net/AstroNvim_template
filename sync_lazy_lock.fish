#!/usr/bin/env fish
# Copy lazy-lock.json from the Neovim configuration in daily use into this
# working copy, so that a plugin set proven by daily use can be reviewed here
# and committed once it is trusted.
#
# The configuration in daily use (~/.config/nvim, a checkout of this repository
# deployed by `icon neovim -c`) is where :Lazy update writes lazy-lock.json.
# This script only copies that file; committing and pushing it stays manual and
# deliberate.

set -l repo_dir (path resolve (status dirname))
set -l dst $repo_dir/lazy-lock.json

set -l config_home $XDG_CONFIG_HOME
test -n "$config_home"; or set config_home $HOME/.config
set -l nvim_config_dir $NVIM_CONFIG_DIR
test -n "$nvim_config_dir"; or set nvim_config_dir $config_home/nvim
set -l src $nvim_config_dir/lazy-lock.json

if not test -f "$src"
    echo "The lock file $src of the Neovim configuration in daily use does not exist." >&2
    exit 1
end

if test "$(path resolve "$src")" = "$(path resolve "$dst")"
    echo "$src and $dst are the same file, so there is nothing to copy."
    exit 0
end

if diff -q "$dst" "$src" >/dev/null 2>&1
    echo "$dst is already identical to $src."
    exit 0
end

# The age of the lock file in daily use is how long the plugin set it pins has
# been exercised, which is the signal for whether it is trusted yet.
set -l age (path mtime -R "$src"); or exit 1
set -l days (math "floor($age / 86400)")
echo "The lock file in daily use was last updated $days day(s) ago."
echo

diff -u "$dst" "$src"
echo

read -l -P "Copy the above lock file into $repo_dir? [y/N] " reply
if not string match -qr '^[Yy]$' -- "$reply"
    echo "Nothing is copied."
    exit 0
end

cp "$src" "$dst"; or exit 1
echo "The lock file has been copied into $dst."
echo "Review it, and then commit and push it to share the plugin set."
