# Design and confirmed rules

Rules confirmed with the Coastal Cloud project lead between Nov 11 and Nov 13, 2026, building on the
Oct 30, 2026 Champions call (Apex for conversion and Opportunity creation; keep Lead Assignment and its emails).

## Which Leads

- **Lead record type:** TOS (`TOS_Lead_Record_Type`) only.
- **When:** only when the Lead is **created** with `HubSpot_Lifecycle_Stage__c = "MQL / Contact"`.
  That field is the HubSpot "nurture MQL" flag. Later edits never queue a Lead.
- **Out of scope:** BD list uploads. They must not arrive with `MQL / Contact` (to confirm with HubSpot admins).

## Order of automation

The existing `Lead_Assignment` flow must run first and stay **unchanged**: owner or queue,
`Matched_Account__c`, and its emails. Do **not** add a "skip MQL" condition to it; flagged Leads would
then get no owner or match.

`Lead_Auto_Convert` uses the flow's async path, so it only runs after the save that ran Lead Assignment
has committed. The worker re-reads the Lead from the database.

## Account matching

1. `Lead.Company` equals `Account.Name` (exact, ignoring case) and exactly **one** Account of record
   type **TOS** has that name → use it.
2. Otherwise, the Lead's `Matched_Account__c` from Lead Assignment, if it is a TOS Account.
3. Otherwise → manual review. This includes two TOS Accounts with the same name, name matches to non-TOS
   Accounts only, and flow matches to deleted or non-TOS Accounts.

For multi-site companies (Pfizer, Bayer, Novartis) the **main Account** is preferred, which is why the
name match runs first. No Account is ever created.

Sandbox data at the time: an exact name match finds one TOS Account for about 42% of TOS Leads. Reps who
converted by hand picked that Account 92% of the time. The flow alone matched about 7%.

## Owners

- Converted Contact and Opportunity owner = the Lead owner.
- Queue-owned Lead (California, Massachusetts, England queues) → the chosen Account's owner.
- No Account or inactive Account owner → fallback user (alias `cjenn`, Colleen Jennings).

## Contact

- Contact record type: General.
- A Contact with the Lead's email already on the chosen Account is **reused**.
- A Contact with that email on a different Account → review (the Contact duplicate rule would block it anyway).

## Opportunity

| Field | Value |
|---|---|
| Record type | TOS |
| Stage | Proposed (stage default probability, 50%) |
| Amount | $1 |
| Close date | Created day 1–21: end of this month. Day 22 or later: end of next month. |
| Principal Investigator | The converted Contact |
| Lead Source, Referred By | Copied from the Lead |
| Name / project number | Set by the existing `Opportunity_Before_Save_Naming_and_Numbering` flow |

One Lead per Account per run, so project numbers stay unique; others wait for the next run.

## Manual review

Status `Needs Manual Review`, a Task on the Lead for the owner, and an email with the reason and a link.
Emails come from `no-reply@championsoncology.com`; the optional **Review Email CC** setting adds copies.
To retry after fixing, set the Status back to `Auto-Convert Pending` (the hourly check picks it up).

## Running user

The worker runs as **API User**, through the platform event trigger's subscriber config
(`deploy/production/`). Rejected options:

- **Automated Process:** can't use the TOS Opportunity record type.
- **Hubspot Integration:** can't see `Matched_Account__c`.
- **Whoever creates the Lead:** inconsistent, and the Coastal Cloud user is blocked from creating
  Opportunities by a validation rule.

## Settings (`Lead_Auto_Convert_Setting__mdt`, record `Default`)

Active, Leads Per Run (10), Pending/Review/Converted statuses, Contact and Opportunity record types,
Opportunity Stage, Opportunity Amount, Close Date Cutoff Day (21), Account Record Types (TOS),
Fallback Owner Alias, Org-Wide Email Address, Review Email CC.

## Known risks

- **HubSpot timing:** if HubSpot creates the Lead first and sets the stage in a later sync, the create-only
  rule won't fire. Check production before the pilot (see TESTING.md).
- **Monitoring:** if API User is deactivated, Leads stay *Auto-Convert Pending*. Add a report or alert for
  Leads pending longer than an hour.
- **Deploys:** pause the hourly check before deploying these classes, then reschedule it.
- **Long outages:** Salesforce lets a failed job re-queue itself only 5 times in a row. If every run
  fails (for example, a broken setting), the retry chain stops after about one Lead and the hourly check
  takes over, so Leads drain to review roughly one per hour. Tested live on Nov 14, 2026. Another reason
  for the pending-Leads monitoring report.
- **Upstream rules already block two failure types:** Leads with a referral Lead Source need Referred By,
  and the Lead duplicate rule blocks a second Lead with the same email.
