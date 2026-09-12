# Resolves the VS Code `code` CLI to an absolute path. Sourced by install.sh
# and update.sh. Prints the path and returns 0, or prints nothing and returns 1.
#
# CODE_BIN_FALLBACKS: colon-separated candidate paths probed when `code` is not
# on PATH (overridable for tests).

: "${CODE_BIN_FALLBACKS:=/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code:/usr/local/bin/code:/usr/bin/code:/snap/bin/code:/usr/share/code/bin/code}"

resolve_code_bin() {
  local found
  if found="$(command -v code 2>/dev/null)" && [ -n "$found" ]; then
    case "$found" in
      /*) printf '%s\n' "$found"; return 0 ;;
    esac
  fi
  local IFS=':' candidate had_globstar
  case $- in *f*) had_globstar=1 ;; *) had_globstar=0 ;; esac
  set -f
  for candidate in $CODE_BIN_FALLBACKS; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      [ "$had_globstar" = 1 ] || set +f
      return 0
    fi
  done
  [ "$had_globstar" = 1 ] || set +f
  return 1
}
