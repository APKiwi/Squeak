# Squeak contributor instructions

Build, install and signing are described in [README.md](README.md).

## Programs, docs and scratch

- Docs describe the system as it is today. Update them in the same commit as the behaviour they describe,
  with each reason or gotcha next to the behaviour it explains. Delete superseded text, git history is the
  archive. Never name a doc by date.
- Long-running program state lives in the owner's program store. Read it with gauge:program_get,
  using the old tracker basename as its id when resuming. Follow docs/programs/README.md. Never commit
  program state under docs/programs/.
- Specs, plans, subagent ledgers and brainstorm output under `docs/superpowers/` and `.superpowers/` are
  local scratch. They are never committed, and no tracked file names a file inside them, whatever a skill
  says. `scripts/check-scratch.sh` enforces this.
- A branch is not done until the docs describe its behaviour and every ruling, reason or gotcha from its
  plan that still applies is in a doc or in the program's decisions in force.
- A merge that reports a modify/delete conflict on a scratch file: copy the file aside, `git rm --cached`
  it, then put the copy back.
