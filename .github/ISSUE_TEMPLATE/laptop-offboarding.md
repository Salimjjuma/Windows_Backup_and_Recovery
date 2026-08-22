---
name: Laptop offboarding
about: Retire or reassign a laptop leaving the backup fleet
title: "Offboard laptop: <hostname>"
labels: offboarding, laptop
---

## Checklist (Maintenance Guide section 8)

- [ ] Confirm most recent backup is current (consider a final restoration
      test if departure is not amicable or data is sensitive)
- [ ] Decide: retain or delete this laptop's repository, and for how long
- [ ] If reassigning the physical laptop to a new user, provision it as a
      **new** laptop under the new hostname/user rather than reusing the
      old repository
- [ ] If any risk of credential exposure: rotate the Wasabi access key at
      minimum (Setup Guide section 6); consider restic password rotation
- [ ] Remove hostname from weekly spot-check and quarterly
      restoration-test rotations

**Hostname:**
**Reason (retiring / reassigning / other):**
**Repository retained or deleted:**
