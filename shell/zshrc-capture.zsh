# Personal config (theme/aliases/p10k) from the HF bucket; absent -> bare shell.
[ -r "$HERMES_PERSONAL_ZSHRC" ] && source "$HERMES_PERSONAL_ZSHRC"

[[ -o interactive && -d $HOME/workspace && $PWD != $HOME/workspace && ( ${PWD:A} == ${HOME:A} || ${PWD:A} == ${HOME:A}/workspace ) ]] && cd "$HOME/workspace"

# ── Install-capture wrappers (zsh-native mirror of the bash set in .bashrc) ──
# Record interactive package installs into $STARTUP_FILE so they replay on the
# next boot and survive Space restarts. STARTUP_FILE is baked below this heredoc.
_hm_append() {
  [ "${HERMES_CAPTURE_DISABLE:-0}" = "1" ] && return 0
  local line="$*"
  mkdir -p "${STARTUP_FILE:h}"
  touch "$STARTUP_FILE"
  chmod +x "$STARTUP_FILE" 2>/dev/null || true
  grep -qxF -- "$line" "$STARTUP_FILE" 2>/dev/null || print -r -- "$line" >> "$STARTUP_FILE"
}
_hm_quote_args() { print -rn -- "${(j: :)${(@q)@}}"; }
_hm_append_cmd() {
  local cmd="$1"; shift
  local args; args="$(_hm_quote_args "$@")"
  if [ -n "$args" ]; then _hm_append "$cmd $args"; else _hm_append "$cmd"; fi
}
_hm_args_without_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      ''|-|--*|-*) ;;
      *) print -r -- "$arg" ;;
    esac
  done
}
_hm_has_install_targets() {
  local item out
  out="$(_hm_args_without_flags "$@")"
  while IFS= read -r item; do
    [ -n "$item" ] && return 0
  done <<< "$out"
  return 1
}
_hm_has_arg() {
  local needle="$1"; shift
  local arg
  for arg in "$@"; do [ "$arg" = "$needle" ] && return 0; done
  return 1
}
pip() {
  command pip "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[2,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "$rest[@]" && ! _hm_has_arg --requirement "$rest[@]" \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "pip install" "$rest[@]"
  fi
  return $rc
}
pip3() {
  command pip3 "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[2,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "$rest[@]" && ! _hm_has_arg --requirement "$rest[@]" \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "pip install" "$rest[@]"
  fi
  return $rc
}
uv() {
  command uv "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[3,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "pip" ] && [ "${2:-}" = "install" ] \
      && ! _hm_has_arg -r "$rest[@]" && ! _hm_has_arg --requirements "$rest[@]" \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "uv pip install" "$rest[@]"
  fi
  return $rc
}
npm() {
  command npm "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[3,-1]}")
  if [ $rc -eq 0 ] && { [ "${1:-}" = "install" ] || [ "${1:-}" = "i" ]; } \
      && { [ "${2:-}" = "-g" ] || [ "${2:-}" = "--global" ]; } \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "npm install -g" "$rest[@]"
  fi
  return $rc
}
hermes() {
  command hermes "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[3,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "plugins" ] && [ "${2:-}" = "install" ] \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "hermes plugins install" "$rest[@]"
  fi
  return $rc
}
