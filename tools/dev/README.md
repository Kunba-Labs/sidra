# Dev harness

- `strippng.py` removes the eXIf chunk that `sips --rotate` leaves in PNGs. Without it, viewers show
  rotated UI-test screenshots sideways. Screenshots land in `build/shots/` (scheme env
  `SIDRA_SHOT_PATH`). For an upright copy: `sips --rotate 270 shot.png && python3 tools/dev/strippng.py shot.png`.
- UI tests launch with `-sidra.noAutoFocus` (keeps the Simulator keyboard down) and
  `-sidra.freshWorkspace` (an empty workspace, no saved hosts).
- Live tests that need an SSH server read `SIDRA_TEST_SSH=user:password@host:port`
  (default `sidra:sidra@localhost:2222`) and skip when it does not answer.
