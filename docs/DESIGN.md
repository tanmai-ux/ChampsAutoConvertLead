# Design and confirmed rules

Rules confirmed with the Coastal Cloud project lead between Nov 11 and Nov 13, 2026, building on the
Oct 30, 2026 Champions call (Apex for conversion and Opportunity creation; keep Lead Assignment and its emails).

## Which Leads

- **Lead record type:** TOS (`TOS_Lead_Record_Type`) only.
- **When:** the Lead has `HubSpot_Lifecycle_Stage__c = "MQL / Contact"` when it is **created**, or gets it
  **within 1 minute of being created**. That field is the HubSpot "nurture MQL" flag. HubSpot sometimes
  creates the Lead first and sends the stage in a follow-up sync (20 seconds later in the sandbox), so the
  1-minute grace window catches it (5 minutes until Nov 17; shortened at the client's request). A Lead is queued only once; Leads that become MQL later are ignored.
- **Out of scope:** BD list uploads. They must not arrive with `MQL / Contact` (to confirm with HubSpot admins).

## Order of automation

The existing `Lead_Assignment` flow must run first and stay **unchanged**: owner or queue,
`Matched_Account__c`, and its emails. Do **not** add a "skip MQL" condition to it; flagged Leads would
then get no owner or match.

`Lead_Auto_Convert` uses the flow's async path, so it only runs after the save that ran Lead Assignment
has committed. The worker re-reads the Lead from the database.

## Account matching

Only Accounts of record type **TOS** count. The first step that applies wins:

1. **Exact name:** `Lead.Company` equals `Account.Name` (ignoring case) for exactly one TOS Account.
2. **Alias:** the Company is listed in **Lead Auto Convert Account Alias** (custom metadata, admin-maintained,
   e.g. `BMS` → `Bristol-Myers Squibb NJ`) and that Account Name is exactly one TOS Account.
3. **Cleaned name:** names match once case, punctuation, `&`/`and`, a leading "The" and trailing legal
   suffixes (Inc, LLC, Ltd, Corp, Co, Company, plc, GmbH, AG, SA, NV, BV, Srl, Pty) are ignored, for
   exactly one TOS Account. Done in Apex on candidates that start with the Company's first word, so no
   Account field or data change is needed.
4. **Lead Assignment's match:** the Lead's `Matched_Account__c`, if it is a TOS Account.
5. Otherwise → manual review.

A name step that finds more than one TOS Account is ambiguous: later name steps are skipped, and only the
flow's match can still be used. Fuzzy matching is deliberately not used for automatic conversion.

For multi-site companies (Pfizer, Bayer, Novartis) the **main Account** is preferred, which is why the
name match runs first. No Account is ever created.

Sandbox data (8,833 TOS Leads): exact name matches 29.1%, cleaned names add 15.5% (44.5% total).
Where reps had converted by hand they chose the same Account 96% (exact) and 84% (cleaned, 19 Leads) of
the time. The flow alone matched about 7%.

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

- **HubSpot timing:** handled by the 1-minute grace window. A stage that arrives more than 1 minute after
  creation is still missed; those Leads appear in the **MQL Leads Not Picked Up** report. Field history on
  HubSpot Lifecycle Stage would show when the stage arrived.
- **Monitoring:** if API User is deactivated, Leads stay *Auto-Convert Pending*. Add a report or alert for
  Leads pending longer than an hour.
- **Deploys:** pause the hourly check before deploying these classes, then reschedule it.
- **Long outages:** Salesforce lets a failed job re-queue itself only 5 times in a row. If every run
  fails (for example, a broken setting), the retry chain stops after about one Lead and the hourly check
  takes over, so Leads drain to review roughly one per hour. Tested live on Nov 14, 2026. Another reason
  for the pending-Leads monitoring report.
- **Upstream rules already block two failure types:** Leads with a referral Lead Source need Referred By,
  and the Lead duplicate rule blocks a second Lead with the same email.
