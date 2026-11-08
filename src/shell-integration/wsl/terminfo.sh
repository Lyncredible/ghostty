# Ghostty's terminfo entry for WSL, sourced by wsl/ghostty.sh.
#
# WSL starts programs with TERM=xterm-256color, and distributions don't ship
# xterm-ghostty yet. The compiled entry next to ghostty.exe can't be used
# from Linux (Windows lays it out by hex directory, `78/`, where Linux's
# ncurses looks in `x/`), so we compile the entry from its source with the
# distribution's `tic`, once, into a cache, and point TERMINFO at it.
#
# Only with the ssh-env or ssh-terminfo features, whose `ssh` wrapper keeps
# SSH working with hosts that don't have the entry (as Ghostty does on
# Linux); without them, TERM stays xterm-256color.
#
# This must stay POSIX sh compatible.

__ghostty_terminfo() {
  case "${GHOSTTY_SHELL_FEATURES-}" in
  *ssh-env* | *ssh-terminfo*) ;;
  *) return 0 ;;
  esac

  __ghostty_ti_src="$GHOSTTY_RESOURCES_DIR/../terminfo/ghostty.terminfo"
  [ -r "$__ghostty_ti_src" ] || return 0
  command -v tic >/dev/null 2>&1 || return 0

  __ghostty_ti_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ghostty/terminfo"
  # Recompile when the source changes (a new Ghostty version).
  __ghostty_ti_sum=$(cksum <"$__ghostty_ti_src" 2>/dev/null) || return 0
  if [ ! -r "$__ghostty_ti_dir/x/xterm-ghostty" ] ||
    [ "$(cat "$__ghostty_ti_dir/.source" 2>/dev/null)" != "$__ghostty_ti_sum" ]; then
    mkdir -p "$__ghostty_ti_dir" 2>/dev/null || return 0
    tic -x -o "$__ghostty_ti_dir" "$__ghostty_ti_src" >/dev/null 2>&1 || return 0
    printf '%s\n' "$__ghostty_ti_sum" >"$__ghostty_ti_dir/.source" 2>/dev/null
  fi
  [ -r "$__ghostty_ti_dir/x/xterm-ghostty" ] || return 0

  export TERMINFO="$__ghostty_ti_dir" TERM=xterm-ghostty
}

__ghostty_terminfo
unset -f __ghostty_terminfo
unset __ghostty_ti_src __ghostty_ti_dir __ghostty_ti_sum
