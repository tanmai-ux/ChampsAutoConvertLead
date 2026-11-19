# Developer Design Notes – MQL Lead Auto-Convert

Champions Oncology · Built by Coastal Cloud · Updated Nov 17, 2026

## 1. What it does

When HubSpot sends a new MQL Lead to Salesforce, this build converts it into a **Contact** and an
**Opportunity** on the right existing **Account**. If it can't find the right Account, it leaves the Lead
for the owner to review and tells them why.

---

## 2. How it works

1. HubSpot creates a **TOS Lead** with **HubSpot Lifecycle Stage = `MQL / Contact`**.
2. The existing **Lead Assignment** flow runs first: it sets the owner (or a regional queue), a
   Matched Account, and sends its usual emails. **We don't change this flow.**
3. Our **Lead Auto Convert** flow marks the Lead **Auto-Convert Pending** and sends a start signal.
4. A background job, running as **API User**, processes waiting Leads 10 at a time.
5. For each Lead it finds the Account (section 3) and then either:
   - **converts** it (section 4), or
   - marks it **Needs Manual Review** and gives the owner a **Task and an email** with the reason.
6. An hourly check restarts the job if it ever stops.

A Lead is picked up when it's **created** as `MQL / Contact`, or when HubSpot sets `MQL / Contact`
**within 1 minute** of creating it (HubSpot sometimes sends the stage in a second sync a few seconds
later). Each Lead is picked up once. A Lead that becomes MQL after 1 minute is ignored and shows up in the *MQL Leads Not Picked Up* report.

---

## 3. How the Account is chosen

Only Accounts with the **TOS** record type count. The first step that finds **exactly one** Account wins:

1. **Exact name** – Lead Company = Account Name (ignoring capitals).
2. **Alias** – an admin-maintained list, e.g. `BMS` → `Bristol-Myers Squibb NJ`.
3. **Cleaned name** – ignores punctuation, "The", and endings like Inc, LLC, Ltd, Corp
   ("Pfizer, Inc." = "PFIZER").
4. **Lead Assignment's match** – the Matched Account, if it's a TOS Account.
5. **Nothing found, or more than one** → manual review.

The build never creates Accounts.

---

## 4. What gets created

| Record | Values |
|---|---|
| **Contact** | Record type General. Reuses an existing Contact with the same email on that Account. |
| **Opportunity** | TOS record type · Stage **Proposed** (50%) · Amount **$1** · Close date: end of this month if created on days 1–21, otherwise end of next month · **Principal Investigator** = the Contact · Lead Source copied |
| **Owner** (both) | The Lead owner. If a queue owns the Lead, the Account owner. |
| **Opportunity name** | Set by the existing naming flow, e.g. `1665-104 Moleculin Biotech` |

---

## 5. When a Lead goes to review

- No TOS Account found by any step.
- More than one TOS Account matches.
- The email already belongs to a Contact on a **different** Account.
- Something fails while converting (the reason is on the Task).

To retry after fixing the Lead: set its Status back to **Auto-Convert Pending**. The hourly check picks it up.

---

## 6. Main components

| Component | What it does |
|---|---|
| `Lead_Auto_Convert` (flow) | Picks up new MQL Leads and queues them |
| `LeadAutoConvertQueueAction` | Marks Leads pending, sends the start signal |
| `Lead_Auto_Convert_Request__e` + trigger + handler | Start signal, so the job always runs as API User |
| `LeadAutoConvertWorker` | Background job: batches of 10, retries on failure |
| `LeadAutoConvertService` | The conversion steps |
| `LeadAutoConvertAccountMatcher` | Chooses the Account |
| `LeadAutoConvertNotifier` | Review Task and email |
| `LeadAutoConvertScheduler` | Hourly safety net |
| `LeadAutoConvertSelector` | All queries |
| `Lead_Auto_Convert_Setting__mdt` | Admin settings |
| `Lead_Auto_Convert_Account_Alias__mdt` | Admin alias list |
| Reports folder **Lead Auto Convert** | *Leads Waiting for Auto-Convert*, *MQL Leads Needing Manual Review*, *MQL Leads Not Picked Up*, *MQL Lead Outcomes* (all MQL Leads grouped by result) |

---

## 7. Settings admins can change (no deploy needed)

Setup → Custom Metadata Types → **Lead Auto Convert Setting** → Default:

| Setting | Value | Notes |
|---|---|---|
| Active | On in sandbox, **off in the repo** | Master on/off switch |
| Leads Per Run | 10 | Keep at 10 |
| Opportunity Stage / Amount | Proposed / 1 | |
| Close Date Cutoff Day | 21 | |
| Account Record Types | TOS | |
| Fallback Owner Alias | cjenn | Used when a queue Lead has no usable Account owner |
| Org-Wide Email Address | no-reply@championsoncology.com | Sender of review emails |
| Review Email CC | blank | Extra recipients for review emails |

Aliases: Setup → Custom Metadata Types → **Lead Auto Convert Account Alias**.

---

## 8. Things to know before you change or deploy

- **Pause the hourly job before deploying these classes**, then reschedule (scripts in `scripts/apex/`).
- **Production deploys:** use RunSpecifiedTests with the three test classes. Running all org tests as the
  Coastal Cloud user fails because a validation rule blocks that user from creating Opportunities.
- **Lead Status values and the TOS Lead Process deploy as full lists** – merge production's values first.
- **The run-as user** is set per org in `deploy/production/`. After changing it, Suspend and Resume the
  subscription (Setup → Platform Events → Lead Auto Convert Request).
- **Creating test Leads in the sandbox emails real people** (Lead Assignment has hard-coded addresses).
  Set Deliverability to System email only, or re-queue existing Leads instead.
- **Don't add a "skip MQL" condition to Lead Assignment** – the build needs it to run first.

---

## 9. Where did a Lead go?

Every TOS MQL Lead ends up in one of these places. Start with the **MQL Lead Outcomes** report
(folder **Lead Auto Convert**), filtered to the import date.

| What you see | Meaning | What to do |
|---|---|---|
| **Qualified** (converted) | Became a Contact and Opportunity. Opportunity Created By = API User means the automation did it. | Nothing |
| **Needs Manual Review** | No single TOS Account matched, or a Contact conflict. The reason is on the Lead's Task. | Fix and convert by hand, or fix the Company and set Status to Auto-Convert Pending |
| **Auto-Convert Pending** | Waiting; normally clears within seconds | If older than a few minutes, check the *Leads Waiting for Auto-Convert* report and Apex Jobs |
| **Not Contacted/New** with MQL / Contact | Never picked up: the stage arrived more than 1 minute after creation, or auto-convert was off | *MQL Leads Not Picked Up* report; convert or re-queue |
| **Not in Salesforce at all** | HubSpot never created the Lead, so the automation never saw it | Check HubSpot (below) |

**HubSpot contacts that never reach Salesforce.** On Nov 17, 2026 HubSpot sent 5 of 9 imported test contacts;
the other 4 never arrived and no Salesforce automation ran for them. Salesforce keeps no record of a
create it rejected, so check HubSpot:

- HubSpot → Settings → Integrations → Salesforce → **Sync Health** (sync errors), or the **Salesforce sync**
  card on the contact.
- Most likely cause: the **Lead duplicate rule blocks** a new Lead whose email already exists on another
  **Lead** (error `DUPLICATES_DETECTED`). Re-imported or reused test emails hit this. (A Lead whose email
  matches a **Contact** is allowed; the automation then reuses that Contact or sends the Lead to review.)
- Other causes: validation rules (for example a referral Lead Source without Referred By), the contact not
  being in HubSpot's sync list, or HubSpot updating an existing Salesforce record instead of creating a Lead.

## 10. Testing

- **Apex:** 39 tests, all passing. Run the three `LeadAutoConvert*Test` classes.
- **The flow's entry rule can't be unit tested:** Salesforce doesn't run a flow's async path inside Apex tests.
  Test it live: create a Lead without the stage, then set it within 1 minute (and after 1 minute).
- **Scenarios:** `scripts/apex/lead-auto-convert-scenarios.apex` creates fresh test data for every case.
- **HubSpot sync simulation:** `python scripts/hubspot-sync-simulation.py champsDev` creates Leads through the
  REST API in batches the way the HubSpot connector does (stage on create, stage 20 s / 80 s later, re-syncs,
  duplicate emails, a 50-Lead batch) and checks all 70 results. Email must be on System only first.
- **Results and step-by-step guide:** [TESTING.md](TESTING.md), [TESTING_GUIDE.md](TESTING_GUIDE.md).

---

## 11. Open items

| Item | Owner |
|---|---|
| Confirm HubSpot sets `MQL / Contact` within 1 minute of creating the Lead in production (20 s seen in the sandbox); watch the *MQL Leads Not Picked Up* report after go-live | Zach, Kendall, admin |
| Confirm BD list uploads never arrive as `MQL / Contact` | Zach, Kendall |
| Add aliases (BMS, GSK, Lilly, DCB, IRB Barcelona) | Champions admin |
| Find why 4 of 9 HubSpot test contacts never synced (Nov 17) – check HubSpot Sync Health | Zach, Kendall |
| Production go-live ([DEPLOYMENT.md](DEPLOYMENT.md)) | Coastal |
| Clean up sandbox test data (`ACT …` records) | Coastal |
