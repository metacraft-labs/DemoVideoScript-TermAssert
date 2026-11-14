## A binding for a terminal application that shows, on its screen, every byte
## the terminal writes to it (`cat -v`: ESC as `^[`), so a check can read what
## an input arrived as: a horizontal wheel as SGR button 66 or 67, a focus
## change as `CSI I` / `CSI O`. It asks for SGR mouse reports, and for focus
## reports when staged with `focus-reports: true`. Its one action,
## `write-file`, is another program writing a file under `$DTA_ACT_DIR`.
##
## The application is a real `sh` script in a real pty; the binding reads its
## rows. Not a stand-in for anything: it is the smallest application that
## shows its input.

import std/[json, options, os, strutils, tables, times]
import term_assert
import demo_video_script/[backend, cli]
import demo_video_script_termassert

const script = """stty raw -echo
printf '\033[?1000h\033[?1006h'
[ "$1" = focus ] && printf '\033[?1004h'
printf 'ready '
exec cat -v"""

proc echoBinding(): TermBinding =
  TermBinding(
    name: "input echo", tracking: mtClick,
    roles: %*{"screen": {"properties": ["text"], "affordances": ["wheel", "click"]}},
    stage: proc (ctx: TermContext; use: string; args: JsonNode) =
      if use != "launch-echo": raise newException(ValueError, "no stage '" & use & "'")
      let mode = if args{"focus-reports"}.getBool(false): "focus" else: "plain"
      ctx.spawnApp("/bin/sh", @["-c", script, "echo", mode], 80, 6)
      ctx.sess.waitForText("ready", initDuration(seconds = 10)),
    surface: proc (ctx: TermContext): Tree =
      var all = ""
      for l in ctx.lines: all.add l.strip(leading = false)
      result.root = node("screen", 0, 0, 80, 6, %*{"text": all}),
    condition: proc (ctx: TermContext; name: string): Option[bool] = none(bool),
    resolveChord: proc (ctx: TermContext; op: string): Option[string] = none(string),
    anchor: nil,
    act: proc (ctx: TermContext; use: string; args: JsonNode) =
      if use != "write-file": raise newException(ValueError, "no action '" & use & "'")
      writeFile(getEnv("DTA_ACT_DIR") / args{"path"}.getStr, args{"content"}.getStr))

when isMainModule:
  var builtins = initTable[string, BackendFactory]()
  builtins["termassert"] = proc (): Backend = newTermAssertBackend(echoBinding())
  dvsMain(builtins)
