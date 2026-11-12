# For install.sh and uninstall.sh.

# Replaces $1 with $1.tmp. A symlink (a dotfiles repo, say) is written
# through, so the link stays and its target changes; mv would replace the link.
replace_file() {
  if [ -L "$1" ]; then
    cat "$1.tmp" >"$1"
    rm -f "$1.tmp"
  else
    mv "$1.tmp" "$1"
  fi
}

# Removes the rex-undo block from init.lua ($1). BSD sed -i refuses symlinks.
remove_block() {
  sed '/^-- rex-undo begin$/,/^-- rex-undo end$/d' "$1" >"$1.tmp"
  replace_file "$1"
}
