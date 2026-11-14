# Deployment

## Before

- Confirm with HubSpot admins that BD list uploads never arrive with `MQL / Contact`.
- Run the read-only HubSpot timing check in `TESTING.md`.
- Confirm the API User username in production:
  `SELECT Username FROM User WHERE Name = 'API User' AND IsActive = true`

## Steps (production)

1. **Retrieve production's `LeadStatus` value set and `TOS` Lead Process** and merge the two new statuses
   into them. The repo copies come from the July sandbox copy and are deployed as full lists.
2. **Validate** (check-only). Use RunSpecifiedTests: run as the Coastal Cloud user, the org's existing tests
   fail on its Opportunity validation rule.
   `sf project deploy validate -o <prod> -d force-app --test-level RunSpecifiedTests -t LeadAutoConvertServiceTest -t LeadAutoConvertWorkerTest -t LeadAutoConvertAccountMatcherTest`
3. **Deploy** the same package (it includes `HubSpot_Lifecycle_Stage__c` and the monitoring reports). The `Default` settings record ships with **Active = false**,
   and the flow ships as Draft.
4. Check the two Lead Status values are in the **TOS** Lead Process.
5. **Run-as user:** `cd deploy/production && sf project deploy start -o <prod> -d force-app`, then
   Setup → Platform Events → Lead Auto Convert Request → Subscriptions → Manage → **Suspend**, then **Resume**.
6. **Activate** the Lead Auto Convert flow.
7. **Schedule** the hourly check as an admin (Anonymous Apex): `LeadAutoConvertScheduler.scheduleHourly();`
8. Subscribe an admin to the **Leads Waiting for Auto-Convert** report (condition: Record Count > 0).
9. Set **Review Email CC** if wanted, then tick **Active** on the `Default` settings record.
10. Watch the first day: Leads in *Auto-Convert Pending* should clear within minutes; review Leads should
   have a Task.

## Later deploys of these classes

Salesforce blocks deploys while the hourly job is scheduled:

1. `scripts/apex/lead-auto-convert-pause-hourly.apex`
2. Deploy.
3. `scripts/apex/lead-auto-convert-schedule-hourly.apex`

## Turning it off

Untick **Active** on the `Default` settings record. No deploy needed; new MQLs are left alone.
Leads created while it is off are **not** picked up when it is switched back on. Convert them by hand,
or set their Status to `Auto-Convert Pending` so the next hourly check converts them.
