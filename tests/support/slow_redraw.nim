## A binding for a terminal application that answers each key in three bursts,
## 150 ms apart ("a", then "ab", then "abc" on its first row), so `settled`
## can be checked deterministically: it must not be reported before the last
## burst. A quiet window is a drain that waits 60 ms of silence and then 60 ms
## more with nothing read, so one quiet window needs a pause of 120 ms and the
## two the adapter requires need 180 ms: a 150 ms pause tells them apart, and
## settling after one window reads the screen mid-redraw (50 ms pauses could
## not tell one window from two).
##
## The application is a real `sh` script in a real pty; the binding reads its
## first row. Not a stand-in for anything: it is the smallest application with
## a multi-burst redraw.

import std/[json, options, strutils, tables, times]
import term_assert
import demo_video_script/[backend, cli]
import demo_video_script_termassert

const script = """stty raw -echo; printf 'ready'
while :; do
  c=$(dd bs=1 count=1 2>/dev/null) || exit 0
  [ -z "$c" ] && exit 0
  printf '\r\033[2Ka'; sleep 0.15
  printf '\r\033[2Kab'; sleep 0.15
  printf '\r\033[2Kabc'
done"""

proc slowBinding(): TermBinding =
  TermBinding(
    name: "slow redraw", tracking: mtNone, roles: newJNull(),
    stage: proc (ctx: TermContext; use: string; args: JsonNode) =
      if use != "launch-slow": raise newException(ValueError, "no stage '" & use & "'")
      ctx.spawnApp("/bin/sh", @["-c", script], 20, 3)
      ctx.sess.waitForText("ready", initDuration(seconds = 10)),
    surface: proc (ctx: TermContext): Tree =
      result.root = node("screen", 0, 0, 20, 3, %*{"text": ctx.lines[0].strip}),
    condition: proc (ctx: TermContext; name: string): Option[bool] = none(bool),
    resolveChord: proc (ctx: TermContext; op: string): Option[string] = none(string),
    anchor: nil)

when isMainModule:
  var builtins = initTable[string, BackendFactory]()
  builtins["termassert"] = proc (): Backend = newTermAssertBackend(slowBinding())
  dvsMain(builtins)
