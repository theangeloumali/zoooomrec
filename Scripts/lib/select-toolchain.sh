#!/usr/bin/env bash
#
# select-toolchain.sh — source this before `swift build`/`swift test`.
#
# zoooomrec's menu-bar app and editor use SwiftUI, whose `@State` macro plugin ships
# ONLY with a full Xcode. Under the standalone Command Line Tools the macro never
# expands and the build dies with a confusing "cannot assign to property: 'self' is
# immutable" (and XCTest is missing outright — see ZR-900 / ZR-909).
#
# Honors a caller-set DEVELOPER_DIR. Otherwise, when Command Line Tools is the active
# toolchain and a full Xcode is installed, it selects that Xcode for THIS process only
# — no sudo, no machine-global `xcode-select -s`.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null || true)" in
    *CommandLineTools*)
      for _candidate in /Applications/Xcode*.app/Contents/Developer; do
        if [ -x "$_candidate/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
          export DEVELOPER_DIR="$_candidate"
          echo "==> toolchain: Command Line Tools lacks the SwiftUI macro plugin;"
          echo "    using Xcode at $DEVELOPER_DIR for this run."
          break
        fi
      done
      unset _candidate
      ;;
  esac
fi
