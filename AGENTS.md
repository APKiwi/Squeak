# Squeak contributor instructions

Build, install and signing are described in [README.md](README.md).

## Programs, docs and scratch

- Docs describe the system as it is today. Update them in the same commit as the behaviour they describe,
  with each reason or gotcha next to the behaviour it explains. Delete superseded text, git history is the
  archive. Never name a doc by date.
- A long-running program, meaning work that spans more than one landing, has one tracker at
  `docs/programs/<name>.md` in the shape [docs/programs/README.md](docs/programs/README.md) sets. Update it
  in the same commit as each milestone. When the program is done, move every decision still in force into
  the docs and delete the tracker.
- Specs, plans, subagent ledgers and brainstorm output under `docs/superpowers/` and `.superpowers/` are
  local scratch. They are never committed, and no tracked file names a file inside them, whatever a skill
  says. `scripts/check-scratch.sh` enforces this.
- A branch is not done until the docs describe its behaviour and every ruling, reason or gotcha from its
  plan that still applies is in a doc or in the program's decisions in force.
- A merge that reports a modify/delete conflict on a scratch file: copy the file aside, `git rm --cached`
  it, then put the copy back.
