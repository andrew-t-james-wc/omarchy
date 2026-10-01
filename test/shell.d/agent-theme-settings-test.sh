#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
theme_dir="$HOME/.local/state/omarchy/current/theme"
mkdir -p "$theme_dir" "$HOME/.pi/agent" "$CLAUDE_CONFIG_DIR" "$test_tmp/dotfiles with spaces"
printf '{}\n' >"$theme_dir/pi.json"
printf '{}\n' >"$theme_dir/claude.json"

for agent in pi claude; do
  if [[ $agent == "pi" ]]; then
    settings="$HOME/.pi/agent/settings.json"
    expected_theme=omarchy-system
  else
    settings="$CLAUDE_CONFIG_DIR/settings.json"
    expected_theme=custom:omarchy
  fi

  for mode in 600 640 644 664; do
    printf '{"model":"keep-me","theme":"old"}\n' >"$settings"
    chmod "$mode" "$settings"
    "$ROOT/bin/omarchy-theme-set-$agent" --activate
    [[ $(stat -c '%a' "$settings") == "$mode" ]] ||
      fail "$agent theme activation preserves mode $mode" "actual mode: $(stat -c '%a' "$settings")"
    jq -e --arg theme "$expected_theme" '.theme == $theme and .model == "keep-me"' "$settings" >/dev/null ||
      fail "$agent theme activation updates the theme and keeps other settings"
  done
  pass "$agent theme activation preserves existing file modes and other settings"

  target="$test_tmp/dotfiles with spaces/$agent-settings.json"
  printf '{"model":"keep-me","theme":"old"}\n' >"$target"
  chmod 640 "$target"
  rm "$settings"
  relative_target=$(realpath --relative-to="$(dirname "$settings")" "$target")
  ln -s "$relative_target" "$settings"
  "$ROOT/bin/omarchy-theme-set-$agent" --activate
  [[ -L $settings && $(readlink "$settings") == "$relative_target" ]] ||
    fail "$agent theme activation keeps the dotfiles symlink"
  [[ $(stat -c '%a' "$target") == "640" ]] || fail "$agent theme activation preserves the target's mode"
  jq -e --arg theme "$expected_theme" '.theme == $theme and .model == "keep-me"' "$target" >/dev/null ||
    fail "$agent theme activation updates the symlink's target"
  pass "$agent theme activation updates the target without replacing the symlink"

  printf '{invalid JSON\n' >"$target"
  cp "$target" "$test_tmp/original"
  if "$ROOT/bin/omarchy-theme-set-$agent" --activate >"$test_tmp/output" 2>&1; then
    fail "$agent theme activation rejects malformed settings"
  fi
  cmp -s "$target" "$test_tmp/original" || fail "$agent failed activation changes no settings"
  [[ -L $settings && $(readlink "$settings") == "$relative_target" ]] ||
    fail "$agent failed activation preserves the symlink"
  pass "$agent failed activation preserves the original settings and symlink"
done
