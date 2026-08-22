---
name: Script change rollout
about: Track a fix or change to install-backup-agent.ps1 / sync-documents.ps1 / test-restore.ps1 across the fleet
title: "Rollout: <short description of the change>"
labels: rollout, script-change
---

## Change management checklist (Maintenance Guide section 9)

- [ ] Change committed to git with a clear message
- [ ] Tested on one laptop (spare/IT-owned, or least-critical in fleet)
      for at least a day before wider rollout
- [ ] Confirmed no regressions in `sync.log` on the test laptop
- [ ] Rolled out fleet-wide by re-running `install-backup-agent.ps1` on
      every laptop (not just ones currently exhibiting the bug - several
      past fixes were latent everywhere)
- [ ] Updated `Backup_Setup_Documentation.md` troubleshooting section if
      this fixes a symptom someone might hit again
- [ ] Closed this issue once all laptops are confirmed on the new version

**What changed:**
**Why:**
**Laptops updated:** (checklist or count, e.g. 0/20)
