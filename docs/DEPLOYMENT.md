# Deployment

## Before

- Confirm with HubSpot admins that BD list uploads never arrive with `MQL / Contact`.
- Run the read-only HubSpot timing check in `TESTING.md`.
- Confirm the API User username in production:
  `SELECT Username FROM User WHERE Name = 'API User' AND IsActive = true`

## Steps (production)

1. **Validate** (check-only) with all org tests:
   `sf project deploy validate -o <prod> -d force-app --test-level RunLocalTests`
2. **Deploy** the same package. The `Default` settings record ships with **Active = false**,
   and the flow ships as Draft.
3. Check the two Lead Status values are in the **TOS** Lead Process.
4. **Run-as user:** `cd deploy/production && sf project deploy start -o <prod> -d force-app`, then
   Setup → Platform Events → Lead Auto Convert Request → Subscriptions → Manage → **Suspend**, then **Resume**.
5. **Activate** the Lead Auto Convert flow.
6. **Schedule** the hourly check as an admin (Anonymous Apex): `LeadAutoConvertScheduler.scheduleHourly();`
7. Set **Review Email CC** if wanted, then tick **Active** on the `Default` settings record.
8. Watch the first day: Leads in *Auto-Convert Pending* should clear within minutes; review Leads should
   have a Task.

## Later deploys of these classes

Salesforce blocks deploys while the hourly job is scheduled:

1. `scripts/apex/lead-auto-convert-pause-hourly.apex`
2. Deploy.
3. `scripts/apex/lead-auto-convert-schedule-hourly.apex`

## Turning it off

Untick **Active** on the `Default` settings record. No deploy needed; new MQLs are left alone.
