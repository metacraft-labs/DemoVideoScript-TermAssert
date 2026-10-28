## DemoVideoScript-TermAssert: the scenario backend protocol over TermAssert.
##
## The adapter answers `locate`, `read`, `send`, `await`, `record` and `hit`
## for a terminal application running in a real pty under TermAssert, using
## only TermAssert's public API. A project supplies a `TermBinding`: its stage
## procedures (which spawn the application), how to derive the tree of role
## instances from the screen, the conditions it can detect, and its binding
## resolver. Locator resolution over that tree is DemoVideoScript's
## (`surface.nim`), so it behaves as on every other tree-producing backend.
##
## Input is delivered as a terminal delivers it, and what TermAssert cannot
## spell is refused, never approximated: Shift or Ctrl with a named key (its
## `sendKey` would drop the modifier), the Meta modifier, a horizontal wheel.
## Pointer motion and drags need the application to have enabled motion
## tracking; the binding declares the mode it enables, and TermAssert refuses a
## motion report the application did not ask for.

import std/[json, os, strutils, times, monotimes, options, tables]
from std/unicode import runes, runeLen, toRunes, runeAt, `$`
import term_assert
import demo_video_script/[backend, surface]

export surface, backend

type
  TermDefect* = enum
    ## Planted defects for the conformance suite's negative arms (§12).
    tdNone = "none", tdStaleRead = "stale-read", tdOffByOne = "off-by-one",
    tdEarlySync = "early-sync", tdReadSideEffect = "read-side-effect"

  TermContext* = ref object
    ## What stages and the binding work with: the session, once spawned.
    sess*: TuiTestSession
    running*: bool
    width*, height*: int
    base*: string                    ## the scenario's directory
    state*: JsonNode                 ## per-run scratch for the binding's stages

  TermBinding* = ref object
    name*: string
    tracking*: MouseTracking         ## the pointer tracking the application enables
    roles*: JsonNode                 ## role -> { affordances, properties } it can deliver
    stage*: proc (ctx: TermContext; use: string; args: JsonNode) {.closure.}
    surface*: proc (ctx: TermContext): Tree {.closure.}
    condition*: proc (ctx: TermContext; name: string): Option[bool] {.closure.}
      ## A condition the binding detects; none() when it does not know the name.
    resolveChord*: proc (ctx: TermContext; operation: string): Option[string] {.closure.}
    anchor*: proc (ctx: TermContext; n: SurfaceNode; anchor: string): Option[(int, int)] {.closure.}

  Recording = object
    on: bool
    dir: string
    t0: MonoTime
    offset: int
    events: seq[JsonNode]
    deterministic: bool
      ## A documentation capture: the cast is a frame of the screen per step,
      ## on the virtual timeline, with the declared volatile regions masked —
      ## the same bytes on every run.

  Adapter = ref object
    b: TermBinding
    ctx: TermContext
    idx: SurfaceIndex
    tree: Tree
    beforeSend: Tree
    hasBefore: bool
    stageClosed: bool
    held: set[KeyModifier]
    defect: TermDefect
    rec: Recording

proc refuse(msg: string): ref BackendError = backendError(beRefused, msg)

proc spawnApp*(ctx: TermContext; cmd: string; args: seq[string]; width, height: int;
               env: seq[(string, string)] = @[]) =
  ## Starts the application in a pty, with the raw byte stream kept for casts.
  var b = newTuiTest(cmd, args).width(width).height(height).transcript(true)
  for (k, v) in env: b = b.envSet(k, v)
  ctx.sess = b.spawn()
  ctx.running = true
  ctx.width = width
  ctx.height = height

proc lines*(ctx: TermContext): seq[string] =
  ## The screen, one string per row, padded to the width.
  for r in 0 ..< ctx.height:
    result.add ctx.sess.regionText(r, 0, ctx.width, 1)

proc requireRunning(a: Adapter) =
  if not a.ctx.running:
    raise backendError(beInternal, "the application is not running (no stage spawned it)")

# --- recording ----------------------------------------------------------------------

proc sample(a: Adapter) =
  ## Appends the bytes the application wrote since the last sample to the cast.
  if not a.rec.on or not a.ctx.running or a.rec.deterministic: return
  discard a.ctx.sess.drainOutput(0)
  let bytes = a.ctx.sess.transcriptBytes()
  if bytes.len > a.rec.offset:
    let t = float((getMonoTime() - a.rec.t0).inMicroseconds) / 1e6
    a.rec.events.add %*[t, "o", bytes[a.rec.offset .. ^1]]
    a.rec.offset = bytes.len

proc writeCast(a: Adapter): string =
  result = a.rec.dir / "session.cast"
  var f = open(result, fmWrite)
  defer: f.close()
  var header = %*{"version": 2, "width": a.ctx.width, "height": a.ctx.height}
  if not a.rec.deterministic: header["timestamp"] = %int(epochTime())
  f.writeLine $header
  for e in a.rec.events: f.writeLine $e

# --- the surface ------------------------------------------------------------------------

const QuietMs = 60

proc settleScreen(a: Adapter; timeoutMs = 3000): bool =
  ## The screen stopped changing: two consecutive windows of `QuietMs` with no
  ## output. One short window is not enough on a loaded machine, where the
  ## application may not have been scheduled yet to answer the input.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var quiet = 0
  while getMonoTime() < deadline:
    if a.ctx.sess.drainOutput(QuietMs) == 0:
      inc quiet
      if quiet >= 2: return true
    else: quiet = 0
  false

proc refresh(a: Adapter) =
  a.requireRunning()
  discard a.ctx.sess.drainOutput(5)
  a.sample()
  a.tree = a.b.surface(a.ctx)

proc treeForRead(a: Adapter): Tree =
  if a.defect == tdStaleRead and a.hasBefore: a.beforeSend
  else:
    a.refresh()
    a.tree

proc cellOf(a: Adapter; id, anchor: string): (int, int) =
  a.refresh()
  let n = a.idx.lookup(a.tree, id)
  var cell = (int(n.y) + int(n.h) div 2, int(n.x) + max(0, int(n.w) div 2 - 1))
  if anchor.len > 0 and anchor != "center":
    let r = (if a.b.anchor == nil: none((int, int)) else: a.b.anchor(a.ctx, n, anchor))
    if r.isNone: raise backendError(beUnsupported, "no anchor '" & anchor & "' on " & n.keyText)
    cell = r.get
  if a.defect == tdOffByOne: inc cell[0]
  cell

proc maskedLines(a: Adapter; mask: JsonNode): seq[string] =
  ## The screen's rows with every masked instance's cells drawn as `#`: a
  ## declared volatile region is the same in every capture.
  result = a.ctx.lines
  if mask == nil or mask.len == 0: return
  a.refresh()
  for id in mask.getElems:
    let n = a.idx.lookup(a.tree, id.getStr)
    for r in int(n.y) ..< min(result.len, int(n.y + n.h)):
      var runes = result[r].toRunes
      for c in int(n.x) ..< min(runes.len, int(n.x + n.w)): runes[c] = "#".runeAt(0)
      result[r] = $runes

proc frame(a: Adapter; seconds: float; mask: JsonNode) =
  ## A deterministic cast's frame: the whole screen, redrawn.
  var rows = a.maskedLines(mask)
  for r in rows.mitems: r = r.strip(leading = false)
  a.rec.events.add %*[seconds, "o", "\e[2J\e[H" & rows.join("\r\n")]

# --- input ------------------------------------------------------------------------------

proc modsOf(names: openArray[string]): set[KeyModifier] =
  for n in names:
    case n
    of "Shift": result.incl kmShift
    of "Alt": result.incl kmAlt
    of "Ctrl": result.incl kmCtrl
    of "Meta": raise refuse("a terminal cannot deliver the Meta modifier")
    else: discard

const namedKeys = {"Enter": "enter", "Esc": "esc", "Tab": "tab", "Backspace": "backspace",
                   "Delete": "delete", "Insert": "insert", "Home": "home", "End": "end",
                   "PageUp": "pageup", "PageDown": "pagedown", "Up": "up", "Down": "down",
                   "Left": "left", "Right": "right", "Space": "space", "F1": "f1", "F2": "f2",
                   "F3": "f3", "F4": "f4", "F5": "f5", "F6": "f6", "F7": "f7", "F8": "f8",
                   "F9": "f9", "F10": "f10", "F11": "f11", "F12": "f12"}.toTable

proc sendKey(a: Adapter; key: string; mods: set[KeyModifier]) =
  ## Through TermAssert's `sendKey`, which encodes modifiers as a terminal
  ## does and raises for a combination no terminal expresses.
  if key in ["Ctrl", "Shift", "Alt", "Meta", "Mod"]:
    raise refuse("a terminal cannot deliver the " & key & " key on its own")
  var name = (if namedKeys.hasKey(key): namedKeys[key] elif key == "Plus": "+" else: key)
  if not namedKeys.hasKey(key) and name.runeLen != 1:
    raise refuse("no terminal encoding for the key '" & key & "'")
  if name.len > 1 and not namedKeys.hasKey(key):
    # one non-ASCII character: typed as itself, and only without modifiers
    if mods != {}: raise refuse("a terminal cannot deliver modifiers with '" & key & "'")
    a.ctx.sess.send(name)
    return
  var prefix = ""
  if kmCtrl in mods: prefix.add "ctrl+"
  if kmAlt in mods: prefix.add "alt+"
  if kmShift in mods: prefix.add "shift+"
  try: a.ctx.sess.sendKey(prefix & name)
  except KeyEncodingError as e: raise refuse(e.msg)

proc pause(ms: float) =
  if ms > 0: sleep(int(ms + 0.5))

proc buttonOf(v: JsonNode): term_assert.MouseButton =
  case v{"button"}.getStr("left")
  of "middle": mbMiddle
  of "right": mbRight
  else: mbLeft

proc follow(a: Adapter; path: JsonNode; held: set[term_assert.MouseButton]; mods: set[KeyModifier]) =
  if path == nil: return
  var last = 0.0
  for p in path:
    pause(p[2].getFloat - last)
    last = p[2].getFloat
    a.ctx.sess.sendMouseMove(int(p[1].getFloat + 0.5), int(p[0].getFloat + 0.5), held, mods)

proc sendAction(a: Adapter; act: JsonNode) =
  a.requireRunning()
  a.refresh()
  a.beforeSend = a.tree
  a.hasBefore = true
  let targets = act{"targets"}
  let timing = act{"timing"}
  try:
    if act.hasKey("ext"):
      raise backendError(beUnsupported, "no extension step '" & act["ext"].getStr & "'")
    elif act.hasKey("key"):
      a.sendKey(act["key"].getStr, a.held)
    elif act.hasKey("chord"):
      for c in act["chord"].getStr.split(' '):
        let parts = c.split('+')
        a.sendKey(parts[^1], a.held + modsOf(parts[0 ..< parts.high]))
    elif act.hasKey("type"):
      let text = (if act["type"].kind == JString: act["type"].getStr else: act["type"]{"text"}.getStr)
      let delays = timing{"keyDelaysMs"}
      var k = 0
      for r in text.runes:
        if delays != nil and k < delays.len: pause(delays[k].getFloat)
        a.ctx.sess.send($r)
        inc k
    elif act.hasKey("press") or act.hasKey("release"):
      let isPress = act.hasKey("press")
      let v = (if isPress: act["press"] else: act["release"])
      if v.hasKey("key"):
        let m = modsOf([v["key"].getStr])
        if m == {}:
          raise refuse("a terminal sends a key's press and release together; it cannot hold '" &
            v["key"].getStr & "'")
        if isPress: a.held = a.held + m else: a.held = a.held - m
      else:
        let (row, col) = a.cellOf(targets["target"].getStr, v{"anchor"}.getStr)
        if isPress: a.ctx.sess.sendMousePress(row, col, buttonOf(v), a.held)
        else: a.ctx.sess.sendMouseRelease(row, col, buttonOf(v), a.held)
    elif act.hasKey("move") or act.hasKey("hover"):
      let v = (if act.hasKey("move"): act["move"] else: act["hover"])
      a.follow(timing{"path"}, {}, a.held)
      let (row, col) = a.cellOf(targets["target"].getStr, v{"anchor"}.getStr)
      a.ctx.sess.sendMouseMove(row, col, {}, a.held)
      if act.hasKey("hover"):
        let f = v{"for"}.getStr("")
        if f.len > 0:
          pause(if f.endsWith("ms"): parseFloat(f[0 ..< f.len - 2])
                elif f.endsWith("s"): parseFloat(f[0 ..< f.len - 1]) * 1000
                else: parseFloat(f) * 1000)
    elif act.hasKey("click"):
      let v = act["click"]
      var mods = a.held
      for m in v{"modifiers"}.getElems: mods = mods + modsOf([m.getStr])
      if timing{"path"} != nil and a.ctx.sess.mouseTracking() == mtMove:
        a.follow(timing["path"], {}, mods)
      let (row, col) = a.cellOf(targets["target"].getStr, v{"anchor"}.getStr)
      for _ in 1 .. v{"count"}.getInt(1):
        a.ctx.sess.sendMouseClick(row, col, buttonOf(v), mods)
    elif act.hasKey("drag"):
      let v = act["drag"]
      var mods = a.held
      for m in v{"modifiers"}.getElems: mods = mods + modsOf([m.getStr])
      let btn = buttonOf(v)
      let fa = (if v["from"].kind == JObject: v["from"]{"anchor"}.getStr else: "")
      let ta = (if v["to"].kind == JObject: v["to"]{"anchor"}.getStr else: "")
      let (r0, c0) = a.cellOf(targets["from"].getStr, fa)
      var waypoints: seq[(int, int)]
      for vid in targets{"via"}.getElems: waypoints.add a.cellOf(vid.getStr, "")
      let (r1, c1) = a.cellOf(targets["to"].getStr, ta)
      if a.ctx.sess.mouseTracking() < mtDrag:
        raise newException(MouseTrackingError, "the application did not enable drag tracking")
      a.ctx.sess.sendMousePress(r0, c0, btn, mods)
      for (r, c) in waypoints: a.ctx.sess.sendMouseMove(r, c, {btn}, mods)
      a.follow(timing{"path"}, {btn}, mods)
      a.ctx.sess.sendMouseMove(r1, c1, {btn}, mods)
      a.ctx.sess.sendMouseRelease(r1, c1, btn, mods)
    elif act.hasKey("wheel"):
      let v = act["wheel"]
      let (row, col) = a.cellOf(targets["target"].getStr, v{"anchor"}.getStr)
      let dir = case v{"direction"}.getStr
        of "up": sdUp
        of "down": sdDown
        else: raise refuse("TermAssert has no horizontal wheel")
      for _ in 1 .. v{"amount"}.getInt(1): a.ctx.sess.sendMouseScroll(row, col, dir)
    else:
      raise backendError(beProtocol, "send: no input action in " & $act)
  except MouseTrackingError as e:
    raise refuse(e.msg)
  a.idx.clear()
  a.sample()

# --- the backend -------------------------------------------------------------------------

proc capabilitiesFor(b: TermBinding): seq[string] =
  result = @["input.key", "input.chord", "input.text", "input.pointer.click", "input.wheel",
             "observe.text", "observe.geometry", "observe.focus", "sync.visual-settle",
             "record.cast", "record.still", "record.mask"]
  if b.tracking >= mtDrag: result.add "input.pointer.drag"
  if b.tracking == mtMove:
    result.add "input.pointer.move"
    result.add "input.hover"

proc newTermAssertBackend*(binding: TermBinding; defect = tdNone): Backend =
  let a = Adapter(b: binding, ctx: TermContext(state: newJObject()), defect: defect)
  result = Backend()
  result.hello = proc (): Hello =
    Hello(backend: "termassert", version: "1", platform: "linux",
          capabilities: capabilitiesFor(binding), bindings: binding.roles, units: "cell")
  result.stage = proc (use: string; args: JsonNode) =
    if a.stageClosed:
      raise backendError(beStageClosed, "the stage has ended; '" & use & "' cannot run now")
    a.ctx.base = args{"$base"}.getStr(".")
    try: binding.stage(a.ctx, use, args)
    except BackendError: raise
    except CatchableError as e: raise backendError(beStage, use & ": " & e.msg)
  result.endStage = proc () =
    a.stageClosed = true
    if a.ctx.running: discard a.settleScreen()
  result.resolveChord = proc (operation: string): Option[string] =
    if binding.resolveChord == nil: none(string) else: binding.resolveChord(a.ctx, operation)
  result.locate = proc (locator: JsonNode): LocateResult =
    a.refresh()
    a.idx.locate(a.tree, locator)
  result.read = proc (instance: string; properties: seq[string]): JsonNode =
    let t = a.treeForRead()
    let n = a.idx.lookup(t, instance)
    result = readNode(n, properties)
    if a.defect == tdReadSideEffect and n.role != binding.surface(a.ctx).root.role:
      # the planted defect: reading clicks the instance with Ctrl
      a.ctx.sess.sendMouseClick(int(n.y), int(n.x) + 1, mbLeft, {kmCtrl})
      discard a.settleScreen(500)
  result.send = proc (action: JsonNode) = a.sendAction(action)
  result.await = proc (condition, instance: string; timeoutMs: int): bool =
    a.requireRunning()
    if a.defect == tdEarlySync: return true
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    if condition == "settled":
      result = a.settleScreen(timeoutMs)
      a.sample()
      return
    while true:
      discard a.ctx.sess.drainOutput(10)
      let met = binding.condition(a.ctx, condition)
      if met.isNone:
        raise backendError(beUnsupported, "the " & binding.name & " binding cannot detect '" &
          condition & "'")
      if met.get:
        a.sample()
        return true
      if getMonoTime() > deadline: return false
  result.record = proc (op: RecordOp; args: JsonNode): JsonNode =
    result = %*{"files": []}
    case op
    of recStart:
      a.rec = Recording(on: true, dir: args{"dir"}.getStr, t0: getMonoTime(),
                        offset: (if a.ctx.running: a.ctx.sess.transcriptBytes().len else: 0),
                        deterministic: args{"deterministic"}.getBool(false))
      # the cast starts from the current screen
      if a.ctx.running:
        if a.rec.deterministic: a.frame(0.0, args{"mask"})
        else:
          a.rec.events.add %*[0.0, "o", "\e[2J\e[H" & a.ctx.sess.screenContents().replace("\n", "\r\n")]
    of recMark:
      if a.rec.on and a.rec.deterministic and a.ctx.running:
        discard a.ctx.sess.drainOutput(5)
        a.frame(args{"virtualMs"}.getFloat / 1000, args{"mask"})
      else: a.sample()
    of recStill:
      a.requireRunning()
      discard a.ctx.sess.drainOutput(5)
      let base = args{"dir"}.getStr(".") / args{"path"}.getStr("still")
      createDir(base.parentDir)
      let mask = args{"mask"}
      if mask != nil and mask.len > 0:
        # TermAssert's renderers draw the screen as it is: a masked still is text
        writeFile(base & ".txt", a.maskedLines(mask).join("\n") & "\n")
        result["files"] = %[base & ".txt"]
      else:
        writeFile(base & ".txt", a.ctx.sess.screenContents())
        writeFile(base & ".svg", renderSvg(a.ctx.sess.screen))
        result["files"] = %[base & ".txt", base & ".svg"]
    of recStop:
      a.sample()
      if a.rec.on and a.rec.dir.len > 0:
        createDir(a.rec.dir)
        result["files"] = %[a.writeCast()]
      a.rec.on = false
  result.hit = proc (x, y: float): Option[string] =
    a.refresh()
    a.tree.hit(x, y)
  result.close = proc () =
    if a.ctx.running:
      a.ctx.sess.terminate()
      a.ctx.sess.close()
      a.ctx.running = false
