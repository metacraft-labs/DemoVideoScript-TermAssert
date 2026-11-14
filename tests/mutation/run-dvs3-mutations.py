#!/usr/bin/env python3
"""DVS-3 verification gate: the TermAssert adapter.

Each arm is a defect in how the adapter delivers input or observes the screen;
the kill command is `just test` (the conformance suite with its planted
defects, and the adapter suite), run against the real application in a pty.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
A = "src/demo_video_script_termassert.nim"

ARMS = [
    Arm("T1", A, "  var cell = (int(n.y) + int(n.h) div 2, int(n.x) + max(0, int(n.w) div 2 - 1))",
        "  var cell = (int(n.y) + int(n.h) div 2 + 1, int(n.x) + max(0, int(n.w) div 2 - 1))",
        "an SGR report one cell off"),
    Arm("T2", A, '    of "Shift": result.incl kmShift', '    of "Shift": discard',
        "the Shift modifier dropped"),
    Arm("T3", A, "  if b.tracking >= mtDrag: result.add \"input.pointer.drag\"",
        "  result.add \"input.pointer.drag\"", "the drag capability declared without motion tracking"),
    Arm("T4", A, "  a.tree = a.b.surface(a.ctx)", "  if not a.hasBefore: a.tree = a.b.surface(a.ctx)",
        "a stale screen read: the screen is not re-read after an input"),
    Arm("T5", A, "  (sampled - quietSince).inMilliseconds >= QuietSpanMs",
        "  (sampled - quietSince).inMilliseconds >= QuietIntervalMs",
        "settled after one quiet read: before the screen stopped changing"),
    Arm("T5b", A, "    if drain(QuietIntervalMs) > 0:\n      quietSince = now()",
        "    if drain(QuietIntervalMs) > 0:\n      discard",
        "output does not restart the quiet span"),
    Arm("T5c", A, "    elif pending() > 0:\n      quietSince = now()", "    elif pending() > 0:\n      discard",
        "settled with input the application has not read yet"),
    Arm("T6", A, '  if kmShift in mods: prefix.add "shift+"', '  discard',
        "Shift dropped from a named key"),
    Arm("T7", A, "  except KeyEncodingError as e: raise refuse(e.msg)",
        "  except KeyEncodingError: a.ctx.sess.sendKey(name)",
        "a key sent without the modifier no terminal can encode"),
    Arm("T8", A, '        of "left": sdLeft', '        of "left": sdRight',
        "the wheel turned left sent as right"),
    Arm("T9", A, '        a.ctx.sess.sendFocus(w["focused"].getBool)', "        a.ctx.sess.sendFocus(true)",
        "a focus loss reported as a gain"),
    Arm("T10", A, "      binding.act(a.ctx, use, args)", "      discard (use, args)",
        "an act step that changes nothing"),
]

if __name__ == "__main__":
    main("dvs3", ROOT, ARMS, ["just", "test"])
