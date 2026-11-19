# Process and gap review (Nov 14, 2026)

## The whole process

| Step | Where | What happens |
|---|---|---|
| 1 | HubSpot | A nurture-route contact reaches MQL. HubSpot syncs it to Salesforce as a **Lead** with `HubSpot Lifecycle Stage = MQL / Contact` (HubSpot mapping; nothing in Salesforce sets this value). |
| 2 | Lead Assignment flow (existing, unchanged) | In the same save: sets the owner or region queue, `Matched_Account__c` by email domain, and sends its assignment emails. |
| 3 | Lead Auto Convert flow | After that save commits (async path), only for TOS Leads created as MQL / Contact: sets Status to *Auto-Convert Pending* and publishes a start request. |
| 4 | Platform event trigger | Runs as **API User** and starts one background job if none is running. |
| 5 | Worker (10 Leads per run, chains until none wait) | Chooses the Account (exact name, alias, cleaned name, then the flow's TOS match), owner (Lead owner, or Account owner for queue Leads), reuses a matching Contact, creates the Opportunity (TOS, Proposed, $1, close-date rule, Principal Investigator), converts the Lead. One Lead per Account per run. |
| 6 | Review | Anything it can't convert: Status *Needs Manual Review*, a Task and an email to the owner with the reason. The rep fixes and converts by hand, or sets the Status back to *Auto-Convert Pending*. |
| 7 | Safety nets | Failed runs retry in smaller groups, then go to review. The hourly check restarts the job. The settings switch turns everything off without a deploy. |
| 8 | Monitoring | Reports in the **Lead Auto Convert** folder: *Leads Waiting for Auto-Convert* (should be empty) and *MQL Leads Needing Manual Review*. |

## Gaps

### Must settle before go-live

| # | Gap | Action | Owner |
|---|---|---|---|
| 1 | ~~HubSpot must set `MQL / Contact` when it creates the Lead.~~ **Mitigated Nov 17:** a real HubSpot sync sent the stage 20 s after creating one Lead, so the flow now also accepts it within 1 minute of creation. Remaining: HubSpot must set it within 1 minute; misses appear in the *MQL Leads Not Picked Up* report. Nothing in Salesforce sets it; the sandbox has no example of HubSpot doing so. | Confirm the HubSpot mapping in production; run the read-only check in TESTING.md. | Zach, Kendall |
| 2 | BD list uploads must never arrive as `MQL / Contact`, or they will convert. | Confirm with HubSpot admins. | Zach, Kendall |
| 3 | The planned "skip flagged records" condition on Lead Assignment would leave MQLs with no owner or match. | Do not add it. | Spencer |
| 4 | Production deploys run as the Coastal Cloud user fail the org's existing tests (its Opportunity validation rule blocks them). | Deploy with RunSpecifiedTests (our three test classes), or as another admin. | Coastal |
| 5 | `LeadStatus` and the TOS Lead Process are deployed as full lists from the July sandbox copy; production may differ. | Retrieve both from production first and merge in the two new values. | Coastal |
| 1b | 4 of 9 HubSpot test contacts never reached Salesforce (Nov 17). Likely the Lead duplicate rule blocking an email already on another Lead (confirmed by simulation: `DUPLICATES_DETECTED`). | Check HubSpot Sync Health; use unique emails in tests. | Zach, Kendall |
| 6 | ~~Review email delivery not yet proven (S13).~~ **Done:** delivered to the project lead's inbox via Review Email CC. | — | — |

### Should do (best practice)

| # | Gap | Recommendation |
|---|---|---|
| 7 | Monitoring needs someone watching. | Subscribe an admin to *Leads Waiting for Auto-Convert* with the condition Record Count > 0 (Setup can't deploy subscriptions). |
| 8 | API User is a full System Administrator, and its username suggests a person (`mweinstein`). If it is deactivated, conversion stops. | Move to a dedicated integration user with a permission set; free Salesforce Integration licenses are available. |
| 9 | ~~59% of TOS Accounts have no Account Number.~~ **Decided Nov 19:** create the Opportunity anyway. The existing naming flow names it like "-100 Company" (Project "-100"); verified live. | — |
| 10 | Long outages drain slowly: a failed job can re-queue itself only 5 times in a row, then the hourly check takes over (about one Lead per hour to review). | Covered by monitoring (#7). Optional: have the hourly check email an admin when Leads wait more than an hour. |
| 11 | ~~Exact name matching misses variants.~~ **Done Nov 14:** cleaned-name matching (29% to 44.5% of sandbox TOS Leads) and an admin alias list. | Client adds aliases for abbreviations seen in review (BMS, GSK, Lilly, DCB, IRB Barcelona). Fuzzy suggestions on review Tasks remain an option. |
| 12 | No permanent error log; reasons live on review Tasks and background job records (kept for a limited time). | Optional log object if the client wants an audit trail. |
| 13 | Volume not yet tested at import scale. | Run the 500-Lead test with sandbox email on System only. |
| 14 | Lead Assignment's role isn't written down on the flow itself. | Add a description to Lead Assignment: "Lead Auto Convert depends on this flow running synchronously first." |
| 15 | Reps need to know the review process. | Short guide: where the Task is, how to convert by hand, how to re-queue. |
| 16 | Sandbox test data. | Delete the `ACT ... 89466` records after sign-off. |

### Checked and in place

- Bulk-safe: no queries or DML in loops; 200-record tests; 10 Leads per run.
- Trigger has no logic (handler pattern); selector, service, notifier split.
- One job at a time, record locking, skips Leads already converted or changed.
- Never creates Accounts; reuses Contacts; per-Lead failure isolation and rollback of unused Opportunities.
- Admin settings and email wording without deploys (custom metadata, custom labels).
- `without sharing` documented on each automation class.
- Tests use the `Assert` class, `@TestSetup`, no `SeeAllData`, and pass with the real hourly job scheduled.
