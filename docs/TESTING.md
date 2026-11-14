# Testing

## 1. Apex tests – done

34 tests pass in champsDev. Coverage per class is 86–100%. They include 200-record bulk tests for matching,
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

## 3. Still to do

- **S13 review email:** with deliverability back on *All email*, re-queue S4 and confirm the email arrives.
- **Edge checks:** off switch, close date after day 21 (temporarily set Close Date Cutoff Day to 5),
  hourly safety net, forced failure recovery, manual re-queue.
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

If new HubSpot Leads arrive with the stage blank and get it later, the create-only rule needs revisiting.
