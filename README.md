# Champions Oncology – MQL Lead Auto-Convert

Apex build that converts new TOS MQL Leads into a Contact and a TOS Opportunity on the
right existing Account, and sends anything it can't convert to the Lead owner for manual review.

- **Design and confirmed rules:** [docs/DESIGN.md](docs/DESIGN.md)
- **Testing (what was run and what's left):** [docs/TESTING.md](docs/TESTING.md)
- **Go-live steps:** [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
- **Process and gap review:** [docs/REVIEW.md](docs/REVIEW.md)

## How it works

1. A TOS Lead is **created** with `HubSpot Lifecycle Stage = MQL / Contact`.
2. The existing **Lead Assignment** flow runs first, unchanged: owner or queue, Matched Account, emails.
3. The **Lead Auto Convert** flow (async path, after the save commits) sets the Lead to
   *Auto-Convert Pending* and publishes a **Lead Auto Convert Request** platform event.
4. The event's trigger runs as **API User** and starts one background job, which works through
   waiting Leads 10 at a time:
   - **Account:** the one TOS Account whose Name equals the Lead's Company (ignoring case);
     otherwise the flow's Matched Account if it is a TOS Account; otherwise manual review.
   - **Owner:** the Lead owner; for queue-owned Leads, the Account owner.
   - **Opportunity:** TOS record type, stage Proposed, Amount $1, close date at the end of this
     month (created day 1–21) or next month (day 22+), Principal Investigator = the new Contact.
   - **Review:** Status *Needs Manual Review*, plus a Task and an email to the owner with the reason.
5. An hourly scheduled check restarts the job if it ever stops.

## Main components (`force-app/main/default`)

| Component | Purpose |
|---|---|
| `flows/Lead_Auto_Convert` | Entry rule (TOS, created as MQL / Contact) and the queue action |
| `classes/LeadAutoConvertQueueAction` | Marks Leads pending and sends the start request |
| `objects/Lead_Auto_Convert_Request__e`, `triggers/LeadAutoConvertRequestTrigger`, `classes/LeadAutoConvertRequestHandler` | Start signal, so the job always runs as the configured user |
| `classes/LeadAutoConvertWorker` | Queueable worker, chaining, failure retry (Transaction Finalizer) |
| `classes/LeadAutoConvertService` | Conversion steps |
| `classes/LeadAutoConvertAccountMatcher` | Account choice (name first, then flow match) |
| `classes/LeadAutoConvertSelector` | All SOQL |
| `classes/LeadAutoConvertNotifier` | Review Task and email |
| `classes/LeadAutoConvertScheduler` | Hourly safety net |
| `objects/Lead_Auto_Convert_Setting__mdt` + `customMetadata/...Default` | Admin settings (on/off switch, values) |
| `standardValueSets/LeadStatus`, `objects/Lead/businessProcesses/TOS` | The two new Lead Status values |
| `labels/CustomLabels` | Review email wording |
| `reports/Lead_Auto_Convert` | Monitoring reports: waiting Leads, Leads needing review |
| `objects/Lead/fields/HubSpot_Lifecycle_Stage__c` | The HubSpot MQL flag field the flow reads |

`deploy/production/` holds the production-only run-as config (usernames differ per org).

## Tests

```
sf project deploy start -o <org> -d force-app --test-level RunSpecifiedTests \
  -t LeadAutoConvertServiceTest -t LeadAutoConvertWorkerTest -t LeadAutoConvertAccountMatcherTest
```

37 Apex tests, including 200-record bulk tests. The sandbox scenario script is in
`scripts/apex/lead-auto-convert-scenarios.apex`.
