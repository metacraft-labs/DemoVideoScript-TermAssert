## The conformance application's terminal binding: its role instances read
## from the screen of its terminal build (`notes-tui`, built from
## DemoVideoScript's conformance/app), as a person reading the terminal would.
##
## What is not drawn cannot be read: a note's body, tags and state are never on
## screen, and the full order of a list that is scrolled is not either. Those
## are declared unreadable, so a scenario that needs them is `unsupported` on
## this backend rather than answered from somewhere else.

import std/[json, os, strutils, options, tables]
from std/unicode import toRunes, runeLen, `$`
import term_assert
import demo_video_script_termassert

proc notesTuiPath(): string =
  result = getEnv("DVS_NOTES_TUI")
  if result.len == 0: result = findExe("notes-tui")
  if result.len == 0:
    raise newException(IOError, "set DVS_NOTES_TUI to the notes-tui binary")

const keymap = {"notes.archive-selected": "Ctrl+d", "notes.rename": "F2", "notes.sort": "Ctrl+s",
                "notes.focus-search": "Ctrl+f", "notes.pin": "Ctrl+p"}.toTable

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["title"], "affordances": []},
    "toolbar": {"properties": [], "affordances": []},
    "toolbar-button": {"properties": ["label", "enabled"], "affordances": ["click"]},
    "search-field": {"properties": ["value", "focused"],
                     "affordances": ["click", "text-entry", "focusable"]},
    "note-list": {"properties": ["count", "order", "first-visible"],
                  "affordances": ["drop-target", "wheel", "focusable"]},
    "note": {"properties": ["title", "selected", "pinned", "position"],
             "affordances": ["click", "double-click", "context-click", "drag-source", "drop-target"]},
    "dialog": {"properties": ["title"], "affordances": []},
    "text-field": {"properties": ["label", "value", "focused"],
                   "affordances": ["click", "text-entry", "focusable"]},
    "dialog-button": {"properties": ["label"], "affordances": ["click"]},
    "context-menu": {"properties": [], "affordances": []},
    "menu-item": {"properties": ["label", "enabled"], "affordances": ["click"]},
    "status-bar": {"properties": ["message"], "affordances": []}}

proc fl(i: int): float = float(i)

proc runeSlice(s: string; a, b: int): string =
  ## Columns [a, b) of a screen row (rows are cells, not bytes).
  let r = s.toRunes
  if a >= r.len: return ""
  $r[a ..< min(b, r.len)]

proc parseScreen(ctx: TermContext): Tree =
  let rows = ctx.lines
  let w = ctx.width
  let h = ctx.height
  let cur = ctx.sess.cursorPosition()
  let curOn = ctx.sess.cursorVisible()
  # overlays first: they cover parts of the list
  var dlgRow = -1
  var dlgCol, dlgW = 0
  for r in 0 ..< h:
    let i = rows[r].find("| Name: ")
    if i >= 0:
      dlgRow = r - 2
      dlgCol = rows[r].toRunes.len - rows[r][i .. ^1].toRunes.len
      let tail = rows[r].toRunes[dlgCol + 1 .. ^1]
      var j = 0
      while j < tail.len and $tail[j] != "|": inc j
      dlgW = j + 2
      break
  var menuRow, menuCol = -1
  var menuItems: seq[(int, string)]
  for r in 0 ..< h:
    let line = rows[r]
    let i = line.find("+----------+")
    if i >= 0 and r != dlgRow and r != dlgRow + 5:
      let col = line.toRunes.len - line[i .. ^1].toRunes.len
      if menuRow < 0:
        menuRow = r
        menuCol = col
        var k = r + 1
        while k < h and rows[k].runeSlice(col, col + 1) == "|":
          menuItems.add (k, rows[k].runeSlice(col + 1, col + 11).strip)
          inc k
  # the window and its fixed parts
  let title = rows[0].strip.split("  ")[0].strip
  var count = 0
  let right = rows[0].strip.splitWhitespace
  if right.len >= 2 and right[^1] == "notes":
    try: count = parseInt(right[^2]) except ValueError: discard
  var t: Tree
  t.root = node("window", 0, 0, fl(w), fl(h), %*{"title": title})
  let tb = node("toolbar", 0, 1, fl(w), 1)
  t.add(t.root, tb)
  var c = 0
  let row1 = rows[1].toRunes
  while c < row1.len:
    if $row1[c] == "[":
      var e = c + 1
      while e < row1.len and $row1[e] != "]": inc e
      let label = $row1[c + 1 ..< e]
      t.add(tb, node("toolbar-button", fl(c), 1, fl(e - c + 1), 1,
                     %*{"label": label, "enabled": true}, @[("label", label)]))
      c = e
    inc c
  var search = node("search-field", 8, 2, fl(w - 8), 1,
                    %*{"value": rows[2].runeSlice(8, w).strip(leading = false),
                       "focused": curOn and cur.row == 2 and dlgRow < 0})
  search.focused = curOn and cur.row == 2 and dlgRow < 0
  t.add(t.root, search)
  # the list
  let listTop = 3
  let listRows = h - 4
  var list = node("note-list", 0, fl(listTop), fl(w), fl(listRows), newJObject())
  t.add(t.root, list)
  var titles: seq[string]
  for k in 0 ..< listRows:
    let r = listTop + k
    let line = rows[r]
    if line.runeSlice(1, 3) != "::": continue
    var text = line.runeSlice(4, w)
    # an overlay covering the right part of the row is not part of the title
    if menuRow >= 0 and r >= menuRow and r < menuRow + menuItems.len + 2:
      text = line.runeSlice(4, menuCol)
    if dlgRow >= 0 and r >= dlgRow and r < dlgRow + 6:
      text = line.runeSlice(4, dlgCol)
    text = text.strip(leading = false)
    var pinned = false
    if text.endsWith(" <"): text = text[0 ..< text.len - 2].strip(leading = false)
    if text.endsWith(" *"):
      pinned = true
      text = text[0 ..< text.len - 2].strip(leading = false)
    titles.add text
    let n = node("note", 0, fl(r), fl(w), 1,
                 %*{"title": text, "selected": line.runeSlice(0, 1) == ">", "pinned": pinned,
                    "position": k + 1}, @[("title", text)])
    t.add(list, n)
  list.props = %*{"count": count, "order": titles,
                  "first-visible": (if titles.len > 0: titles[0] else: "")}
  if count != titles.len:
    list.unreadable["order"] = "only " & $titles.len & " of " & $count & " notes are on screen"
    for n in t.kids(list):
      n.unreadable["position"] = "the list is scrolled, so a row's place in it is not on screen"
  list.focused = dlgRow < 0 and not (curOn and cur.row == 2)
  t.add(t.root, node("status-bar", 0, fl(h - 1), fl(w), 1, %*{"message": rows[h - 1].strip}))
  if dlgRow >= 0:
    let dlg = node("dialog", fl(dlgCol), fl(dlgRow), fl(dlgW), 6, %*{"title": "Rename"},
                   @[("title", "Rename")])
    t.add(t.root, dlg)
    let value = rows[dlgRow + 2].runeSlice(dlgCol + 8, dlgCol + dlgW - 1).strip(leading = false)
    let field = node("text-field", fl(dlgCol + 8), fl(dlgRow + 2), fl(dlgW - 10), 1,
                     %*{"label": "Name", "value": value, "focused": true}, @[("label", "Name")])
    field.focused = true
    t.add(dlg, field)
    t.add(dlg, node("dialog-button", fl(dlgCol + 2), fl(dlgRow + 4), 4, 1, %*{"label": "OK"},
                    @[("label", "OK")]))
    t.add(dlg, node("dialog-button", fl(dlgCol + 7), fl(dlgRow + 4), 8, 1, %*{"label": "Cancel"},
                    @[("label", "Cancel")]))
  if menuRow >= 0:
    let menu = node("context-menu", fl(menuCol), fl(menuRow), 12, fl(menuItems.len + 2))
    t.add(t.root, menu)
    for (r, label) in menuItems:
      t.add(menu, node("menu-item", fl(menuCol + 1), fl(r), 10, 1,
                       %*{"label": label, "enabled": true}, @[("label", label)]))
  t

proc notesBinding*(): TermBinding =
  TermBinding(
    name: "notes-app terminal",
    tracking: mtMove,          # notes-tui enables DEC 1003 (any motion) and 1006
    roles: roles(),
    stage: proc (ctx: TermContext; use: string; args: JsonNode) =
      case use
      of "seed-notes":
        let f = args{"fixture"}.getStr
        ctx.state["fixture"] = %(if f.isAbsolute: f else: ctx.base / f)
      of "launch-app":
        var a: seq[string]
        if ctx.state.hasKey("fixture"): a.add @["--fixture", ctx.state["fixture"].getStr]
        let w = args{"width"}.getInt(60)
        let h = args{"height"}.getInt(16)
        a.add @["--width", $w, "--height", $h]
        ctx.spawnApp(notesTuiPath(), a, w, h)
        ctx.sess.waitForText("Notes", initDuration(seconds = 10))
      of "set-clock": discard
      of "mark-started":
        let p = args{"path"}.getStr
        writeFile((if p.isAbsolute: p else: ctx.base / p), "the stage ran\n")
      else: raise newException(ValueError, "no stage procedure '" & use & "'"),
    surface: parseScreen,
    condition: proc (ctx: TermContext; name: string): Option[bool] =
      case name
      of "note-list.loaded", "idle":
        some(ctx.sess.regionText(ctx.height - 1, 0, ctx.width, 1).strip != "Loading...")
      else: none(bool),
    resolveChord: proc (ctx: TermContext; operation: string): Option[string] =
      if keymap.hasKey(operation): some(keymap[operation]) else: none(string),
    anchor: proc (ctx: TermContext; n: SurfaceNode; anchor: string): Option[(int, int)] =
      let name = anchor.split('(')[0]
      case name
      of "handle": some((int(n.y), int(n.x) + 1))
      of "title-end": some((int(n.y), int(n.x) + 4 + n.props{"title"}.getStr.runeLen - 1))
      of "caret-at":
        let col = parseInt(anchor[anchor.find('(') + 1 ..< anchor.find(')')])
        some((int(n.y), int(n.x) + col))
      else: none((int, int)))
