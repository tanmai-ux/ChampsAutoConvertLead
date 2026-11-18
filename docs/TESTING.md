# Testing

## 1. Apex tests – done

39 tests pass in champsDev. Coverage per class is 86–100%. They include 200-record bulk tests for matching,
review, the queue action and the worker, plus rules such as name vs flow match, TOS-only, queue owner,
Contact reuse/conflict, the close-date rule (year end, leap year), $1 / Proposed / Principal Investigator,
failure retry and the off switch.

## 2. Sandbox scenarios – done (Nov 12, 2026, champsDev)

Run with `scripts/apex/lead-auto-convert-scenarios.apex` (records named `ACT ... 89466`). Email
deliverability was set to System only during the run. All conversions ran as API User; every Opportunity
was Proposed, $1, TOS, closing 2026-11-30, with Principal Investigator set.

| # | Scenario | Result |
|---|---|---|
| S1 | Company equals a TOS Account name | Converted onto that Account |
| S2 | No name match; Lead Assignment matched by domain | Converted onto the flow's Account |
| S3 | Name match and a different flow match | Name match won |
| S4 | No match | Review: "No TOS Account is named ..., and the Lead Assignment flow found no matching Account." |
| S5 | Name matches only a Hospital Account | Review |
| S6 | Flow matched a non-TOS Account | Review |
| S7 | Lead in the California Leads queue | Contact and Opportunity owned by the Account owner |
| S8 | Contact with same email on the Account | Existing Contact reused |
| S9 | Contact with same email on another Account | Review |
| S10 | Two Leads, same Account | Both converted in separate runs; project numbers -100 and -101 |
| S11 | TOS Lead created without MQL / Contact | Not touched |
| S12 | POS Lead with MQL / Contact | Not touched |

## 3. Live edge checks – done (Nov 14, 2026)

| # | Check | Result |
|---|---|---|
| S14 | Off switch | MQL Lead created while Active was off was left alone |
| S15 | Good Leads around another Lead | Both converted |
| S16 | Close date after cutoff (cutoff temporarily 5) | Close date 2026-12-31; cutoff restored to 21 |
| S17 | Forced failure on every run | Retries 10, 5, 2, 1, then review with the error; chain stopped after 5 retries (platform limit) |
| S18 | Hourly safety net | 17:00 check picked up the Lead left waiting and sent it to review |
| S19 | Manual re-queue | Fixed Lead set back to pending, converted by the 17:00 check (project number -102) |
| S20 | Company "act name match 89466, Inc." | Converted onto ACT Name Match 89466 (cleaned name) |
| S21 | Company "ACT ALIAS 89466" with a sandbox-only alias record | Converted onto ACT Flow Only 89466 (alias) |
| S22 | Company "The ACT Contact Reuse 89466 LLC" | Converted onto ACT Contact Reuse 89466 (cleaned name) |

Found and fixed: the scheduler test reused the real job name and failed whenever the hourly job was
scheduled, which would have blocked production deploys. All tests (39 now) pass with the job scheduled.

### S13 – review email delivered

Confirmed by the project lead: a review email arrived in their inbox through the **Review Email CC**
setting (sandbox users' own addresses end in `.invalid`, so the CC is how delivery is proven).

### Full re-run after the matching change (Nov 14, 2026, tag 82195)

All scenarios re-run on fresh records with the final matcher (exact, alias, cleaned name, flow): **17 of 17
checks passed**. S1–S12 and S20–S22 as above, plus checks that every converted Opportunity is Proposed,
$1, 50% probability, TOS, closing 2026-11-30, created by API User with Principal Investigator set, and that
S10's project numbers are unique (99959-100 / 99959-101).

### Nov 17, 2026 – with sandbox email on

- **Review email (re-queue):** S4, S5 and S9 (tag 82195) set back to Auto-Convert Pending. All returned to
  Needs Manual Review with new Tasks and the right reasons; the project lead received **3 emails** via the
  Review Email CC. Lead Assignment sent nothing (no new Leads).
- **Conversion (re-queue):** the same Leads pointed at TOS Accounts and re-queued. All converted as API User:
  S4 by exact name (project number 99959-102, continuing -100/-101), S5 by cleaned name ("…, Inc."), S9 onto the
  Account holding the existing Contact, which was **reused**. All Opportunities Proposed, 50%, $1, closing
  2026-11-30, TOS, Principal Investigator set. No emails sent.

### Nov 17, 2026 – grace window (email on System only)

| # | Test | Result |
|---|---|---|
| S23 | Lead created **without** the stage at 20:21:37; stage set at 20:21:52 (like HubSpot's late sync) | Picked up 4 s later and **converted** by API User (99959-105 ACT Shared 82195) |
| S24 | Lead created without the stage at 20:21:37; stage set at 20:27:40 (after 5 minutes) | **Ignored** as intended: stayed Not Contacted/New, no status change |
| S25 | Lead created as MQL, went to review; then another field edited | Stayed in review; no second Task, no new status change |
| S26 | Window shortened to **1 minute**. Lead created at 20:51:51 without the stage; stage set at 20:52:06 (15 s) | Picked up and **converted** by API User (99959-107) |
| S27 | Lead created at 20:51:51 without the stage; stage set at 20:53:09 (78 s) | **Ignored**; appears in the *MQL Leads Not Picked Up* report |

S23–S25 ran with the original 5-minute window; S26–S27 with the final 1-minute window.

The real HubSpot sync on Nov 17 (Leads created by the HubSpot connection user) converted 2 Leads and sent 2 to
review correctly; one Lead (Tan Mai) was skipped because HubSpot sent its stage 20 s after creating it – the
case the grace window now covers.

**Tan Mai (real HubSpot Lead skipped before the change):** re-queued on Nov 17 and converted onto ACT Shared 82195
(Opportunity 99959-106). Full list of test records: [TEST_RECORDS.md](TEST_RECORDS.md).

### Nov 17, 2026 – re-run after code clean-up (tag 15828)

Small clean-up (comments, test counter, queue-owner check, settings parsing). 39/39 Apex tests pass. Full
scenario script re-run with email on System only: S1–S12 and S20–S22 all as expected – queue Lead owned by the
Account owner (Earl Major), existing Contact reused, S10 numbers -100/-101, review reasons correct.

## 4. Still to do

- **Volume:** ~500-Lead import (45% name match, some domain match, some shared Accounts, rest unmatched)
  with deliverability on System only. Check all processed, no failed jobs, unique project numbers, run time.
- **End to end with HubSpot:** HubSpot isn't connected to champsDev (its last sandbox Lead is from June 5,
  2026). Options: connect a HubSpot test account to the sandbox, or run a short controlled pilot in
  production with Active off until the window.

### End-to-end checks

1. HubSpot test contact reaches MQL on the nurture route.
2. A Salesforce Lead is created by Hubspot Integration with `MQL / Contact` **set on create**.
3. Lead Assignment sets owner or queue, Matched Account, and sends its emails.
4. Within about a minute the Lead is converted by API User; check the Contact and Opportunity.
5. HubSpot syncs to the new Contact, with no duplicate Lead and no sync errors.
6. An unmatched test contact goes to review.
7. A BD list-upload contact is not converted.

### Check before the pilot (production, read-only)

```sql
SELECT Id, CreatedDate, LastModifiedDate, HubSpot_Lifecycle_Stage__c
FROM Lead
WHERE CreatedBy.Name = 'Hubspot Integration' AND CreatedDate = LAST_N_DAYS:30
ORDER BY CreatedDate DESC
```

HubSpot Leads that get the stage within 1 minute of creation are picked up (grace window, added Nov 17). Check that production HubSpot syncs stay inside that window using the *MQL Leads Not Picked Up* report.
