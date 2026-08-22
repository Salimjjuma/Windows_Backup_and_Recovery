---
name: Laptop onboarding
about: Provision a new laptop into the backup fleet
title: "Onboard laptop: <hostname>"
labels: onboarding, laptop
---

## Checklist

- [ ] Run `install-backup-agent.ps1` on the laptop (Setup Guide section 3)
- [ ] Confirm the first snapshot appears (Setup Guide section 5:
      `restic snapshots`)
- [ ] Confirm scheduled task shows `LogonType: S4U` (Setup Guide section 8e)
- [ ] Add hostname to the weekly spot-check rotation
- [ ] Add hostname to the quarterly restoration-test rotation
- [ ] Note hostname + provisioning date somewhere durable (this issue is fine)

**Hostname:**
**Assigned user:**
**Date provisioned:**
