## The `dvs` command line with the TermAssert backend and the conformance
## application's terminal binding linked in process:
##
##   --backend termassert                  the adapter
##   --backend termassert-<defect>         with a planted defect (stale-read,
##                                         off-by-one, early-sync, read-side-effect)
##
## `--serve` instead serves the same backend over JSON lines on stdio
## (`--serve --defect=<defect>` for a planted one), which is how
## out-of-process consumers reach the in-process adapter.

import std/[os, strutils, tables]
import demo_video_script/[backend, cli, jsonlines]
import term_assert
import demo_video_script_termassert
import ./notes_binding

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--serve":
    var defect = tdNone
    for a in args[1 .. ^1]:
      if a.startsWith("--defect="): defect = parseEnum[TermDefect](a[9 .. ^1])
    serveJsonLines(newTermAssertBackend(notesBinding(), defect))
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["termassert"] = proc (): Backend = newTermAssertBackend(notesBinding())
  for d in [tdStaleRead, tdOffByOne, tdEarlySync, tdReadSideEffect]:
    let defect = d
    builtins["termassert-" & $d] = proc (): Backend = newTermAssertBackend(notesBinding(), defect)
  # the application's binding claiming only click tracking: drags and motion
  # are then not admitted (§4.9)
  builtins["termassert-click-only"] = proc (): Backend =
    let b = notesBinding()
    b.tracking = mtClick
    newTermAssertBackend(b)
  dvsMain(builtins)
