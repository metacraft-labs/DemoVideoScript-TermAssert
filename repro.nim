## repro.nim — DemoVideoScript-TermAssert for reprobuild.
##
## The terminal backend for DemoVideoScript scenarios, consumed as Nim library
## SOURCE (SC-11): a product's scenario pack links its binding against
## `src/demo_video_script_termassert.nim`, the runner (DemoVideoScript) and the
## terminal harness (TermAssert, which brings TermAssertClient, nim-pty and
## nim-libvterm). Declaring them here lets a consumer's lock pin the set this
## backend was built against. The repository's own tests run through its
## Justfile.
import repro_project_dsl

package demo_video_script_termassert:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "DemoVideoScript"
    "TermAssert"
  library demo_video_script_termassert
  build:
    # Nothing is built here: the library is consumed as source, and the
    # repository's tests run through its Justfile. A package with no
    # `build:` block is not solved, so the lock would record nothing.
    discard
