## Justfile - DemoVideoScript-TermAssert.
##
## Sibling sources come from .github/sibling-repos checkouts next to this one;
## each can be overridden (DVS_SRC, TERM_ASSERT_SRC, NIM_PTY_SRC,
## NIM_LIBVTERM_SRC, TERM_ASSERT_CLIENT_SRC). Build outputs go under BUILD_DIR.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

build_dir := env_var_or_default("BUILD_DIR", "build")
bin := build_dir / "bin"
dvs_src := env_var_or_default("DVS_SRC", "../DemoVideoScript/src")
dvs_root := dvs_src / ".."
paths := "--path:src --path:" + dvs_src + " --path:" + env_var_or_default("TERM_ASSERT_SRC", "../TermAssert/src") + " --path:" + env_var_or_default("NIM_PTY_SRC", "../nim-pty/src") + " --path:" + env_var_or_default("NIM_LIBVTERM_SRC", "../nim-libvterm/src") + " --path:" + env_var_or_default("TERM_ASSERT_CLIENT_SRC", "../TermAssertClient/src")
nim_flags := "--hints:off --passC:-w --mm:orc --threads:on"
pack := dvs_root / "conformance/pack/notes-app.pack.yaml"
scenarios := dvs_root / "conformance/scenarios"

# The adapter with the conformance binding (`dvs-termassert-notes`), and the
# conformance application's terminal build (`notes-tui`) from the pinned
# DemoVideoScript. The tests never build these themselves.
build:
    @mkdir -p {{bin}}
    nim c {{nim_flags}} -d:release {{paths}} --nimcache:{{build_dir}}/nimcache/dta -o:{{bin}}/dvs-termassert-notes conformance/dvs_termassert_notes.nim
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/notes-tui -o:{{bin}}/notes-tui {{dvs_root}}/conformance/app/notes_tui.nim
    nim c {{nim_flags}} -d:release {{paths}} --nimcache:{{build_dir}}/nimcache/slow-redraw -o:{{bin}}/slow-redraw tests/support/slow_redraw.nim

test: build test-conformance test-adapter

# §12: every admitted scenario passes in fast and realistic modes, every
# other is unsupported, and every planted defect turns a scenario red.
test-conformance:
    DVS_NOTES_TUI={{bin}}/notes-tui {{bin}}/dvs-termassert-notes conformance --pack {{pack}} \
      --backend termassert \
      --defect stale-read=termassert-stale-read --defect off-by-one=termassert-off-by-one \
      --defect early-sync=termassert-early-sync --defect read-side-effect=termassert-read-side-effect \
      {{scenarios}}/*.yaml

test-adapter:
    @mkdir -p {{build_dir}}/test-bin
    DVS_NOTES_TUI={{bin}}/notes-tui DVS_BIN_DIR={{bin}} DVS_ROOT={{dvs_root}} \
      nim c -r {{nim_flags}} {{paths}} --nimcache:{{build_dir}}/nimcache/test_adapter -o:{{build_dir}}/test-bin/test_adapter tests/test_adapter.nim

lint: lint-nim lint-neutrality lint-nix

lint-nim:
    nim check {{nim_flags}} {{paths}} conformance/dvs_termassert_notes.nim
    nim check {{nim_flags}} {{paths}} tests/test_adapter.nim

lint-neutrality:
    bash {{dvs_root}}/tests/neutrality_scan.sh $(git ls-files | grep -vE '^(flake.lock)$' | sed "s|^|$PWD/|")

lint-nix:
    nixfmt --check flake.nix

format:
    nixfmt flake.nix

clean:
    rm -rf {{build_dir}}
