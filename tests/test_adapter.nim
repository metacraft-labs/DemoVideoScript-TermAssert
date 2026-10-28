## The TermAssert adapter on the conformance application's terminal build, in a
## real pty: fast and realistic runs, out of process over JSON lines, the cast
## it records, and what it refuses. Every check runs the real application
## through the built `dvs-termassert-notes`; no stand-ins.

import std/[json, os, osproc, strutils, unittest, streams, strtabs, algorithm]
import nim_libvterm

let bin = getEnv("DVS_BIN_DIR", "build/bin")
let tool = bin / "dvs-termassert-notes"
let dvsRoot = getEnv("DVS_ROOT", "../DemoVideoScript")
let pack = dvsRoot / "conformance/pack/notes-app.pack.yaml"
let scenarios = dvsRoot / "conformance/scenarios"
let here = currentSourcePath().parentDir

proc runJson(scenario, backend: string; extra: seq[string] = @[]): JsonNode =
  let p = startProcess(tool, args = @["run", scenario, "--pack", pack, "--backend", backend,
                                      "--json", "--record", "off"] & extra,
                       options = {poStdErrToStdOut})
  let o = p.outputStream.readAll()
  discard p.waitForExit()
  p.close()
  for line in o.splitLines:
    if line.startsWith("{"): return parseJson(line)
  raise newException(ValueError, "no result: " & o)

proc statuses(r: JsonNode): seq[string] =
  for s in r["steps"]: result.add s["path"].getStr & ":" & s["status"].getStr

suite "the TermAssert adapter":
  test "in process and over JSON lines give identical step results":
    for name in ["archive-from-keyboard", "context-menu-pin"]:
      let f = scenarios / name & ".yaml"
      let a = runJson(f, "termassert")
      let b = runJson(f, "cmd:" & tool & " --serve")
      checkpoint name & ": " & $a["message"] & " / " & $b["message"]
      check a["outcome"].getStr == "passed"
      check b["outcome"].getStr == "passed"
      check statuses(a) == statuses(b)

  test "a drag reorders the list through TermAssert's press, motion and release":
    let r = runJson(scenarios / "drag-to-reorder.yaml", "termassert", @["--mode", "realistic"])
    checkpoint $r["message"]
    check r["outcome"].getStr == "passed"

  test "an application that enables only click tracking admits no drag":
    let r = runJson(scenarios / "drag-to-reorder.yaml", "termassert-click-only")
    check r["outcome"].getStr == "unsupported"
    check r["unsupported"][0]["capability"].getStr == "input.pointer.drag"

  test "what is not on screen is unsupported, not answered from elsewhere":
    let r = runJson(scenarios / "search-and-matchers.yaml", "termassert")
    check r["outcome"].getStr == "unsupported"
    var caps: seq[string]
    for u in r["unsupported"]: caps.add u["capability"].getStr
    check "binding.note.property.body" in caps
    check "binding.note.property.tags" in caps

  test "Shift with a named key reaches the application":
    let r = runJson(here / "scenarios/shift-arrow.yaml", "termassert")
    checkpoint $r["message"]
    check r["outcome"].getStr == "passed"

  test "a key no terminal can encode is refused, never sent without its modifier":
    let r = runJson(here / "scenarios/ctrl-enter.yaml", "termassert")
    check r["outcome"].getStr == "failed"
    check "no terminal encoding for ctrl+enter" in $r["steps"]

  test "settled waits for the last of several redraw bursts":
    let slow = bin / "slow-redraw"
    for i in 1 .. 3:
      let p = startProcess(slow, args = ["run", here / "scenarios/slow-redraw.yaml", "--pack",
                                         here / "support/slow.pack.yaml", "--backend", "termassert",
                                         "--record", "off"], options = {poStdErrToStdOut})
      let o = p.outputStream.readAll()
      let code = p.waitForExit()
      p.close()
      checkpoint o
      check code == 0

  test "a realistic run records a cast that replays to the final screen":
    let dir = getTempDir() / "dta-cast-" & $getCurrentProcessId()
    defer: removeDir(dir)
    let p = startProcess(tool, args = ["run", scenarios / "archive-from-keyboard.yaml", "--pack",
                                       pack, "--backend", "termassert", "--mode", "realistic",
                                       "--record", "always", "--out", dir],
                         options = {poStdErrToStdOut})
    discard p.outputStream.readAll()
    check p.waitForExit() == 0
    p.close()
    let castLines = readFile(dir / "session.cast").strip.splitLines
    let header = parseJson(castLines[0])
    check header["version"].getInt == 2
    var s = newScreen(header["height"].getInt, header["width"].getInt)
    var last = -1.0
    for line in castLines[1 .. ^1]:
      let e = parseJson(line)
      check e[0].getFloat >= last
      last = e[0].getFloat
      check e[1].getStr == "o"
      s.feed(e[2].getStr)
    var still: seq[string]
    for l in readFile(dir / "steps/9-after-archive.txt").splitLines: still.add l.strip(leading = false)
    var replayed: seq[string]
    for r in 0 ..< header["height"].getInt:
      replayed.add s.region(r, 0, header["width"].getInt, 1).strip(leading = false)
    while still.len > 0 and still[^1] == "": discard still.pop
    while replayed.len > 0 and replayed[^1] == "": discard replayed.pop
    check replayed == still
    check fileExists(dir / "steps/9-after-archive.svg")

proc runIn(build: string; args: seq[string]): (string, int) =
  var e = newStringTable()
  for k, v in envPairs(): e[k] = v
  e["BUILD_DIR"] = build
  let p = startProcess(tool, args = args, env = e, options = {poStdErrToStdOut})
  let o = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (o, code)

proc runsOf(build, scenario: string): seq[string] =
  let g = build / "scenario-runs" / scenario / "termassert"
  if dirExists(g):
    for kind, p in walkDir(g):
      if kind == pcDir: result.add p
  result.sort()

suite "recordings and documentation captures on the terminal":
  test "a failing run leaves its recording under the build directory":
    let build = getTempDir() / "dta-fail-" & $getCurrentProcessId()
    defer: removeDir(build)
    let (o, code) = runIn(build, @["run", here / "scenarios/broken-expectation.yaml", "--pack",
                                   pack, "--backend", "termassert"])
    checkpoint o
    check code == 1
    let runs = runsOf(build, "termassert-broken-expectation")
    check runs.len == 1
    check ("recording: " & runs[0]) in o
    let m = parseJson(readFile(runs[0] / "manifest.json"))
    check m["outcome"].getStr == "failed"
    for f in ["steps/1-state.json", "steps/1-key.txt", "steps/1-key.svg", "steps/2-state.json",
              "failure/observation.json", "failure/surface.txt", "failure/backend.log"]:
      checkpoint f
      check fileExists(runs[0] / f)
    check fileExists(runs[0] / "session.cast")

  test "an undeclared live clock fails a capture run; declared, two runs are byte-identical":
    let build = getTempDir() / "dta-det-" & $getCurrentProcessId()
    defer: removeDir(build)
    let f = here / "scenarios/clock-capture.yaml"
    let (o, code) = runIn(build, @["run", f, "--pack", pack, "--backend", "termassert",
                                   "--record", "always", "--deterministic"])
    checkpoint o
    check code == 1
    check "an undeclared volatile region" in o
    for i in 0 .. 1:
      let (o2, c2) = runIn(build, @["run", f, "--pack", pack, "--backend", "termassert",
                                    "--record", "always", "--deterministic", "--pin", "clock",
                                    "--env", "LANG=C.UTF-8"])
      checkpoint o2
      check c2 == 0
      sleep(1100)
    let runs = runsOf(build, "termassert-clock-capture")
    check runs.len == 3
    let a = runs[1]
    let b = runs[2]
    for name in ["session.cast", "steps/3-first-selected.txt", "steps/5-second-selected.txt"]:
      checkpoint name
      check readFile(a / name) == readFile(b / name)
    check "#" in readFile(a / "steps/3-first-selected.txt").splitLines[0]
    let (p, pc) = runIn(build, @["capture-path", "scenario=termassert/clock-capture",
                                 "capture=second-selected"])
    check pc == 0
    check p.strip == b / "steps/5-second-selected.txt"
