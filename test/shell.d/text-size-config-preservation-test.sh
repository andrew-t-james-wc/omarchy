#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command getfacl
require_command setfacl
require_command python3

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export HOME="$test_tmp/home"
export OMARCHY_TEST_DESKTOP_LOG="$test_tmp/desktop.log"
mkdir -p "$HOME/.config/omarchy" "$test_tmp/bin" "$test_tmp/dotfiles with spaces"

cat >"$test_tmp/bin/gsettings" <<'SH'
#!/bin/bash
if [[ $1 == "get" && $3 == "font-name" ]]; then
  echo "'Adwaita Sans 11'"
else
  printf '%s\n' "$*" >>"$OMARCHY_TEST_DESKTOP_LOG"
fi
SH
cat >"$test_tmp/bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$test_tmp/bin/cp" <<'SH'
#!/bin/bash
if [[ ${OMARCHY_TEST_FAIL_STAGE:-} == "attributes" && $1 == "--attributes-only" ]]; then
  exit 71
fi
command -p cp "$@"
SH
for command in awk mv; do
  cat >"$test_tmp/bin/$command" <<'SH'
#!/bin/bash
command_name=${0##*/}
if [[ ${*: -1} == "$OMARCHY_TEST_SETTINGS_TARGET" &&
  ( $command_name == "awk" && ${OMARCHY_TEST_FAIL_STAGE:-} == "transform" ||
    $command_name == "mv" && ${OMARCHY_TEST_FAIL_STAGE:-} == "publish" ) ]]; then
  exit 72
fi
command -p "$command_name" "$@"
SH
done
chmod +x "$test_tmp/bin"/*
export PATH="$test_tmp/bin:$PATH"

settings="$HOME/.config/omarchy/shell.toml"
target="$test_tmp/dotfiles with spaces/shell.toml"
export OMARCHY_TEST_SETTINGS_TARGET="$target"
printf '[font]\nbase-size = 12\nfamily = "keep-me"\n[bar]\nheight = 30\n' >"$target"
chmod 640 "$target"
setfacl -m u:65534:r "$target"
expected_acl=$(getfacl -cpn "$target")
alternate_group=""
for group in $(id -G); do
  if [[ $group != "$(id -g)" ]]; then
    alternate_group=$group
    break
  fi
done
if [[ -n $alternate_group ]]; then
  chgrp "$alternate_group" "$target"
else
  skip "supplemental-group preservation needs membership in a second group"
fi
expected_owner=$(stat -c '%u:%g' "$target")
python3 - "$target" <<'PY'
import os, sys
os.setxattr(sys.argv[1], 'user.omarchy-test', b'keep-me')
PY
relative_target=$(realpath --relative-to="$(dirname "$settings")" "$target")
ln -s "$relative_target" "$settings"

assert_config_preserved() {
  [[ -L $settings && $(readlink "$settings") == "$relative_target" ]] || fail "text sizing preserves the settings symlink"
  [[ $(getfacl -cpn "$target") == "$expected_acl" ]] || fail "text sizing preserves file modes and ACLs"
  [[ $(stat -c '%u:%g' "$target") == "$expected_owner" ]] || fail "text sizing preserves file ownership"
  python3 - "$target" <<'PY'
import os, sys
assert os.getxattr(sys.argv[1], 'user.omarchy-test') == b'keep-me'
PY
  grep -Fxq 'family = "keep-me"' "$target" || fail "text sizing preserves other font settings"
  grep -Fxq 'height = 30' "$target" || fail "text sizing preserves other sections"
}

"$ROOT/bin/omarchy-display-text-size" 16
assert_config_preserved
grep -Fxq 'base-size = 16' "$target" || fail "text sizing updates the settings referent"
pass "setting text size preserves the symlink, access metadata and unrelated settings"

"$ROOT/bin/omarchy-display-text-size" reset
assert_config_preserved
if grep -q 'base-size' "$target"; then fail "reset removes the size override from the referent"; fi
pass "resetting text size preserves the symlink and access metadata"

cp "$target" "$test_tmp/original"
for action in 16 reset; do
  for stage in transform attributes publish; do
    : >"$OMARCHY_TEST_DESKTOP_LOG"
    if OMARCHY_TEST_FAIL_STAGE="$stage" "$ROOT/bin/omarchy-display-text-size" "$action" >"$test_tmp/output" 2>&1; then
      fail "text sizing must propagate a failure during $stage"
    fi
    cmp -s "$target" "$test_tmp/original" || fail "failed text sizing preserves the original settings"
    assert_config_preserved
    [[ ! -s $OMARCHY_TEST_DESKTOP_LOG ]] || fail "failed config publication must stop GTK changes"
    for candidate in "$target".*; do
      [[ ! -e $candidate ]] || fail "failed text sizing leaves no temporary config files" "$candidate"
    done
  done
done
pass "failed settings publication leaves the original intact and stops desktop changes"

rm "$settings"
for mode in 600 640 644 664; do
  printf '[font]\nbase-size = 12\n' >"$settings"
  chmod "$mode" "$settings"
  "$ROOT/bin/omarchy-display-text-size" 16
  [[ $(stat -c '%a' "$settings") == "$mode" ]] || fail "text sizing preserves a regular file's mode"
  "$ROOT/bin/omarchy-display-text-size" reset
  [[ $(stat -c '%a' "$settings") == "$mode" ]] || fail "text size reset preserves a regular file's mode"
done
pass "setting and resetting text size preserve regular config file modes"

rm "$settings"
"$ROOT/bin/omarchy-display-text-size" 16
grep -Fxq 'base-size = 16' "$settings" || fail "text sizing still creates a missing config"
pass "setting text size still creates a missing config"
