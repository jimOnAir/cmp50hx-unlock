# 22 — RTD3/D3cold keep-powered conffile (fleet insurance)

Type: build (deb)
Status: ready-for-agent
Blocked by: — (can start immediately)
Source row: B2-P26 (tools/disable-rtd3.sh + warm-resume-entry/report.md:20)

## What to build

D3cold rail-off erases the AON-kept unlock (and the ticket-16 canary's
AON half names exactly this culprit). Ship an optional, documented
modprobe conffile line `options nvidia NVreg_DynamicPowerManagement=0x00`
— NOT enabled-by-default on the current desktop-server fleet (slots
don't park; silent behavior changes are banned), shipped COMMENTED in
its own file under /etc/modprobe.d/ with a pointer comment in the
README diagnostics section, plus `cmp-tune`-style --check one-liner
reporting current power/control per card.

## Acceptance criteria

- [ ] Conffile shipped commented; smoke gate asserts it exists + is
      commented; no boot behavior change on llm2-class hosts.
