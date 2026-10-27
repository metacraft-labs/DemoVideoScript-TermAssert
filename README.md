# DemoVideoScript-TermAssert

The [DemoVideoScript](https://github.com/metacraft-labs/DemoVideoScript) scenario backend
for terminal applications, over [TermAssert](https://github.com/metacraft-labs/TermAssert):
a scenario runs against the real application in a real pty, with a real `libvterm`
screen.

A project supplies a **binding** (`TermBinding`): its stage procedures (which spawn the
application), how its page objects are read from the screen, the conditions it can
detect, and its binding resolver. The adapter answers the backend protocol with it —
`locate`, `read`, `send`, `await`, `record`, `hit` — in process, and over JSON lines
for out-of-process consumers.

What it delivers, and what it refuses:

- keys, chords and typing as a terminal sends them; Shift or Ctrl with a named key
  (TermAssert's `sendKey` cannot spell it), the Meta modifier and a horizontal wheel
  are refused, never sent without the modifier;
- clicks, the wheel, and — when the application enables motion tracking, which the
  binding declares — pointer moves, hovers and drags (TermAssert's press, motion and
  release);
- reads through the binding's view of the screen: what is not drawn cannot be read,
  and a scenario that needs it is `unsupported` here;
- recordings as asciinema v2 casts, and stills as text and SVG.

The conformance application's binding (`conformance/notes_binding.nim`) is the worked
example, and `dvs-termassert-notes` is the `dvs` command line with it linked in:

```sh
dvs-termassert-notes run scenario.yaml --pack notes-app.pack.yaml --backend termassert
dvs-termassert-notes --serve        # the same backend over JSON lines on stdio
```

## Developing

The siblings named in `.github/sibling-repos` are expected next to this checkout
(`../DemoVideoScript`, `../TermAssert`, `../nim-pty`, `../nim-libvterm`,
`../TermAssertClient`), or at the paths in `DVS_SRC`, `TERM_ASSERT_SRC`, … In the dev
shell:

| Recipe | Does |
|---|---|
| `just build` | the adapter's command line and the conformance application's terminal build |
| `just test` | the conformance suite (fast and realistic, with every planted defect), and the adapter suite |
| `just lint` | `nim check`, the neutrality scan, `nixfmt` |
| `python3 tests/mutation/run-dvs3-mutations.py` | every planted defect in the adapter must turn `just test` red |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
