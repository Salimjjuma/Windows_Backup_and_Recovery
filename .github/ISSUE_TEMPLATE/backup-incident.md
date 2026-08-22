---
name: Backup incident
about: A laptop's backups failed, a restoration test failed, or a laptop was lost/stolen
title: "Incident: <short description>"
labels: incident
---

## What happened

**Type:** (lost/stolen laptop / silent backup failure / restoration test
failure / other)
**Hostname(s) affected:**
**How this was discovered:**

## Investigation (Maintenance Guide section 10)

- [ ] Checked `sync.log` for last successful backup / error details
- [ ] Checked `Get-ScheduledTaskInfo -TaskName DocumentsBackupSync` /
      `LastTaskResult`
- [ ] Determined whether this is isolated to one laptop or fleet-wide
      (if uncertain, ran an out-of-cycle spot-check across a broader
      sample - section 3)

## Resolution

**Root cause:**
**Fix applied:**
**Follow-up needed** (e.g. credential rotation, documentation update):
