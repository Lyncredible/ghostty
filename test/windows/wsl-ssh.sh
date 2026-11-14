#!/bin/sh
# Checks the WSL version of `ghostty +ssh` (shell-integration/wsl/bin/ghostty)
# and the shells' ssh wrapper guard, inside a WSL distribution, with a fake
# ssh (no sshd needed) that answers `ssh -G` and runs the terminfo installer
# locally. HOME is a temporary directory, so the user's files are untouched.
#
#     wsl.exe -e sh test/windows/wsl-ssh.sh /mnt/c/.../zig-out/share/ghostty

set -u
resources=${1:?usage: wsl-ssh.sh <GHOSTTY_RESOURCES_DIR as a Linux path>}
shim="$resources/shell-integration/wsl/bin/ghostty"
failures=0

fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}
pass() { printf 'ok: %s\n' "$*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME"
export GHOSTTY_RESOURCES_DIR="$resources" TERM=xterm-ghostty

# The fake ssh logs its arguments and TERM. `-G` prints a config; a command
# that installs terminfo runs locally, reading stdin like the remote would.
fake="$tmp/ssh"
cat >"$fake" <<'EOF'
#!/bin/sh
printf 'ARGS %s\nTERM %s\n' "$*" "$TERM" >>"$FAKE_SSH_LOG"
if [ "$1" = -G ]; then
  printf 'user tester\nhostname example.test\nport %s\n' "${FAKE_SSH_PORT:-22}"
  exit 0
fi
for last; do :; done
case "$last" in
*"tic -x"*)
  [ -z "${FAKE_SSH_FAIL-}" ] || exit 1
  sh -c "$last"
  exit $?
  ;;
esac
exit 0
EOF
chmod +x "$fake"
export FAKE_SSH_LOG="$tmp/log"

run() {
  : >"$FAKE_SSH_LOG"
  "$shim" +ssh --ssh="$fake" "$@" >"$tmp/stdout" 2>"$tmp/stderr"
}
final_term() { grep '^TERM ' "$FAKE_SSH_LOG" | tail -n 1 | cut -d' ' -f2; }
installs() { grep -c 'tic -x' "$FAKE_SSH_LOG"; }
cache="$XDG_STATE_HOME/ghostty/ssh_cache"

# First connection: installs, caches, TERM=xterm-ghostty, forwards env.
run user@example.test
[ "$(installs)" = 1 ] && pass "first connection installs terminfo" || fail "no install: $(cat "$FAKE_SSH_LOG")"
[ -f "$HOME/.terminfo/x/xterm-ghostty" ] && pass "tic compiled xterm-ghostty" || fail "no compiled entry under $HOME/.terminfo"
# The remote login shell may not be POSIX, so the installer runs under sh.
grep -q "^ARGS .* sh -c 'tic -x" "$FAKE_SSH_LOG" && pass "the install runs under sh -c" || fail "install command: $(grep 'tic -x' "$FAKE_SSH_LOG")"
[ "$(final_term)" = xterm-ghostty ] && pass "TERM=xterm-ghostty" || fail "TERM was $(final_term)"
grep -q 'SendEnv=TERM_PROGRAM_VERSION' "$FAKE_SSH_LOG" && pass "forwards env with SendEnv" || fail "no SendEnv"
grep -q '^tester@example.test|[0-9]*|wsl-' "$cache" 2>/dev/null && pass "cached tester@example.test" || fail "cache: $(cat "$cache" 2>/dev/null)"

# Second connection: cached, no install.
run user@example.test
[ "$(installs)" = 0 ] && [ "$(final_term)" = xterm-ghostty ] && pass "second connection uses the cache" || fail "second connection: $(cat "$FAKE_SSH_LOG")"

# A non-default port is a separate host.
FAKE_SSH_PORT=2222 run -p 2222 user@example.test
[ "$(installs)" = 1 ] && grep -q '^tester@example.test:2222|' "$cache" && pass "port 2222 cached separately" || fail "port: $(cat "$cache")"

# --terminfo=false: no install, xterm-256color.
run --terminfo=false user@example.test
[ "$(installs)" = 0 ] && [ "$(final_term)" = xterm-256color ] && pass "--terminfo=false uses xterm-256color" || fail "--terminfo=false: $(cat "$FAKE_SSH_LOG")"

# --forward-env=false: no SendEnv.
run --forward-env=false user@example.test
grep -q SendEnv "$FAKE_SSH_LOG" && fail "--forward-env=false still sends env" || pass "--forward-env=false sends nothing"

# A failed install (no tic on the remote) falls back with a warning.
FAKE_SSH_FAIL=1 run --cache=false user@example.test
[ "$(final_term)" = xterm-256color ] && grep -q 'failed to install terminfo' "$tmp/stderr" && pass "a failed install falls back to xterm-256color" || fail "failed install: $(cat "$tmp/stderr")"

# The cache is private to the user.
[ "$(stat -c %a "$cache")" = 600 ] && pass "the cache is mode 600" || fail "cache mode $(stat -c %a "$cache")"

# A remote command: no install (which would run it an extra time, with the
# terminfo source as its input), and the command runs once. Options'
# values (-p 22, -o X, combined as -vp 22) aren't the destination.
for args in 'user@example.test ./deploy.sh now' '-l me -p 2222 example.test ./deploy.sh' \
  '-vp 2222 example.test ./deploy.sh' '-oBatchMode=yes example.test ./deploy.sh'; do
  # shellcheck disable=SC2086 # split on purpose
  run --cache=false $args
  [ "$(installs)" = 0 ] && [ "$(grep '^ARGS' "$FAKE_SSH_LOG" | grep -v '^ARGS -G' | grep -c 'deploy.sh')" = 1 ] &&
    pass "a remote command runs once, with no install ($args)" || fail "remote command ($args): $(cat "$FAKE_SSH_LOG")"
done
# Without one, options and their values still install.
for args in '-p 2222 example.test' '-vp 2222 example.test' '-o BatchMode=yes -- example.test' '-v example.test'; do
  # shellcheck disable=SC2086 # split on purpose
  run --cache=false $args
  [ "$(installs)" = 1 ] && pass "no remote command installs ($args)" || fail "no install ($args): $(cat "$FAKE_SSH_LOG")"
done

# ssh -G (and other options without a session) go straight to ssh.
run -G user@example.test
[ "$(installs)" = 0 ] && [ "$(grep -c '^ARGS' "$FAKE_SSH_LOG")" = 1 ] && pass "ssh -G passes through" || fail "-G: $(cat "$FAKE_SSH_LOG")"

# Bad flags and other commands are errors.
"$shim" +ssh --bogus x 2>/dev/null; [ $? = 2 ] && pass "unknown flag exits 2" || fail "unknown flag"
"$shim" +version 2>/dev/null; [ $? = 1 ] && pass "other commands exit 1" || fail "other command"

# The launcher points GHOSTTY_BIN_DIR at the shim for the ssh features (its
# ssh block only: the rest starts a shell).
dir=$(GHOSTTY_SHELL_FEATURES=ssh-terminfo sh -c '
  sed -n "/^case \"\${GHOSTTY_SHELL_FEATURES-}\" in/,/^esac/p" "$GHOSTTY_RESOURCES_DIR/shell-integration/wsl/ghostty.sh" >"$0.part"
  __ghostty_dir="$GHOSTTY_RESOURCES_DIR/shell-integration"
  . "$0.part"
  printf %s "${GHOSTTY_BIN_DIR-}"' "$tmp/launcher")
[ -x "$dir/ghostty" ] && pass "the launcher sets GHOSTTY_BIN_DIR ($dir)" || fail "launcher GHOSTTY_BIN_DIR='$dir'"

# TERM=xterm-ghostty in WSL, with the ssh features: the entry is compiled
# into a cache once, and programs find it through TERMINFO.
terminfo_sh="$resources/shell-integration/wsl/terminfo.sh"
if command -v tic >/dev/null && command -v infocmp >/dev/null; then
  got=$(GHOSTTY_SHELL_FEATURES=ssh-terminfo TERM=xterm-256color sh -c '. "$0"; printf "%s|%s" "$TERM" "${TERMINFO-}"' "$terminfo_sh")
  term=${got%%|*} terminfo=${got#*|}
  [ "$term" = xterm-ghostty ] && [ "$terminfo" = "$XDG_CACHE_HOME/ghostty/terminfo" ] &&
    pass "the ssh features give TERM=xterm-ghostty ($terminfo)" || fail "terminfo: '$got'"
  TERMINFO="$terminfo" infocmp -x xterm-ghostty >/dev/null 2>&1 &&
    pass "infocmp finds xterm-ghostty there" || fail "infocmp can't read $terminfo"
  [ "$(TERMINFO="$terminfo" TERM=xterm-ghostty tput Smulx 2>/dev/null | wc -c)" -gt 0 ] &&
    pass "programs see its capabilities (Smulx)" || fail "no Smulx"
  stamp=$(stat -c %Y "$terminfo/x/xterm-ghostty")
  sleep 1
  GHOSTTY_SHELL_FEATURES=ssh-env sh -c '. "$0"' "$terminfo_sh"
  [ "$(stat -c %Y "$terminfo/x/xterm-ghostty")" = "$stamp" ] &&
    pass "a second start reuses the compiled entry" || fail "recompiled it"
  got=$(GHOSTTY_SHELL_FEATURES=cursor,title TERM=xterm-256color sh -c '. "$0"; printf "%s|%s" "$TERM" "${TERMINFO-}"' "$terminfo_sh")
  [ "$got" = "xterm-256color|" ] && pass "without the ssh features TERM stays xterm-256color" || fail "no ssh features: '$got'"
else
  printf 'skip: no tic or infocmp in this distribution\n'
fi

# The bash and zsh integrations only wrap ssh when ghostty is there.
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  if [ "$shell" = bash ]; then
    check='source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash" >/dev/null 2>&1; type -t ssh'
  else
    # zsh defines its wrappers in a deferred init, at the first prompt.
    check='source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" >/dev/null 2>&1; _ghostty_deferred_init >/dev/null 2>&1; whence -w ssh'
  fi
  without=$(GHOSTTY_SHELL_FEATURES=ssh-terminfo GHOSTTY_BIN_DIR= "$shell" -ic "$check" 2>/dev/null)
  with=$(GHOSTTY_SHELL_FEATURES=ssh-terminfo GHOSTTY_BIN_DIR="${shim%/*}" "$shell" -ic "$check" 2>/dev/null)
  case "$without" in *function*) fail "$shell wraps ssh without ghostty" ;; *) pass "$shell leaves ssh alone without ghostty" ;; esac
  case "$with" in *function*) pass "$shell wraps ssh with ghostty" ;; *) fail "$shell doesn't wrap ssh with ghostty: '$with'" ;; esac
done

if [ "$failures" -gt 0 ]; then
  printf '%s check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
