# Ghostty shell integration launcher for WSL.
#
# Ghostty on Windows runs this inside a WSL distribution with
# `wsl.exe [options] --exec /bin/sh -c '. ".../wsl/ghostty.sh"'`, passing
# GHOSTTY_RESOURCES_DIR (translated to a Linux path) and
# GHOSTTY_SHELL_FEATURES through WSLENV. It starts the user's login shell
# with the same automatic integration Ghostty uses for that shell natively.
#
# This must stay POSIX sh compatible since it runs before the user's shell.

__ghostty_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
[ -n "$__ghostty_shell" ] || __ghostty_shell=${SHELL:-/bin/sh}
export SHELL="$__ghostty_shell"

__ghostty_dir="$GHOSTTY_RESOURCES_DIR/shell-integration"

case "${__ghostty_shell##*/}" in
bash)
  if [ -r "$__ghostty_dir/bash/ghostty.bash" ]; then
    # Like Ghostty's native bash integration: start in POSIX mode so bash
    # sources $ENV, and let our script restore the normal startup.
    [ -n "$ENV" ] && export GHOSTTY_BASH_ENV="$ENV"
    export ENV="$__ghostty_dir/bash/ghostty.bash"
    export GHOSTTY_BASH_INJECT=1
    if [ -z "$HISTFILE" ]; then
      export HISTFILE="$HOME/.bash_history"
      export GHOSTTY_BASH_UNEXPORT_HISTFILE=1
    fi
    exec "$__ghostty_shell" --posix -l
  fi
  ;;
zsh)
  if [ -d "$__ghostty_dir/zsh" ]; then
    [ -n "$ZDOTDIR" ] && export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"
    export ZDOTDIR="$__ghostty_dir/zsh"
  fi
  ;;
elvish | fish | nu)
  if [ -d "$__ghostty_dir" ]; then
    export GHOSTTY_SHELL_INTEGRATION_XDG_DIR="$__ghostty_dir"
    export XDG_DATA_DIRS="$__ghostty_dir:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  fi
  if [ "${__ghostty_shell##*/}" = nu ]; then
    exec "$__ghostty_shell" -l --execute 'use ghostty *'
  fi
  ;;
esac

case "${__ghostty_shell##*/}" in
bash | zsh | fish | sh | dash | ksh | mksh) exec "$__ghostty_shell" -l ;;
*) exec "$__ghostty_shell" ;;
esac
