# Testing Guide – MQL Lead Auto-Convert

How to test the build in the **champsDev** sandbox: what to set up, what to test, what you should see, and
how to avoid emailing real people. Results of past runs are in [TESTING.md](TESTING.md); the design is in
[DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md).

---

## 1. Before you start

### Check the setup

| Check | Where | Expected |
|---|---|---|
| Settings switched on | Setup → Custom Metadata Types → Lead Auto Convert Setting → Manage → **Default** | Active ticked, Account Record Types `TOS`, Close Date Cutoff Day 21 |
| Flow active | Setup → Flows → **Lead Auto Convert** | Active |
| Run-as user | Setup → Platform Events → Lead Auto Convert Request → Subscriptions | Trigger **Running** (config points at API User) |
| Hourly check scheduled | Setup → Scheduled Jobs | "Lead Auto-Convert hourly check" |
| Nothing stuck | Report **Lead Auto Convert → Leads Waiting for Auto-Convert** | 0 rows |

### Who gets emailed (important)

| What happens | Who receives email in the sandbox |
|---|---|
| **A new Lead is created** | The existing **Lead Assignment** flow emails **real, hard-coded addresses**: tcates@ and cjennings@ (default), plus regional teams for CA, MA and UK queue Leads. |
| A Lead **converts** | Nobody. |
| A Lead goes to **review** | The owner's user email (ends in `.invalid` in the sandbox, so not delivered) and the **Review Email CC** address in the settings. |
| An existing Lead is **edited** | Nobody (Lead Assignment only runs on create). |

**Rules of thumb**

- Testing conversions or anything that **creates Leads** → set Setup → Deliverability to **System email only** first.
- Testing the **review email** → set **All email**, put your address in **Review Email CC**, and **re-queue an existing
  Lead** instead of creating one (section 4).

### Who can create test Leads

Only admins can edit **HubSpot Lifecycle Stage**. Any admin works: conversion always runs as API User,
whoever creates the Lead. Set the stage when the Lead is first saved, or **within 5 minutes** of creating it;
after 5 minutes, setting it does nothing.

---

## 2. Automated tests (Apex)

```
sf apex run test -o champsDev -n LeadAutoConvertServiceTest -n LeadAutoConvertWorkerTest -n LeadAutoConvertAccountMatcherTest -w 20 -r human -c
```

Expected: **39 passed, 0 failed.** They run safely with the real hourly job scheduled.

| Class | What it proves |
|---|---|
| `LeadAutoConvertServiceTest` | Each conversion rule: matching paths, owners, Contact reuse/conflict, Opportunity values, close-date rule, review Task and email (incl. CC), rollback of unused Opportunities, skip/defer, 200-Lead bulk review |
| `LeadAutoConvertWorkerTest` | One worker at a time, chaining, failure retry (10→5→2→1) and review, off switch, queue action (200 Leads), platform event delivery, hourly scheduler |
| `LeadAutoConvertAccountMatcherTest` | Name cleaning, exact → alias → cleaned → flow order, ambiguity, non-TOS Accounts, deleted matches, 200 Leads in 2 queries |

---

## 3. Full scenario run (scripted)

Creates fresh, tagged test data (`ACT ... <tag>`) covering every scenario in one go.

1. Set Deliverability to **System email only** (the script creates 16 Leads).
2. Run: `sf apex run -o champsDev -f scripts/apex/lead-auto-convert-scenarios.apex`
   The output ends with `SCENARIOS={...}` – the tag plus every Account and Lead Id.
3. Wait 1–2 minutes (10 Leads per run, then it chains).
4. Check each Lead against the table below (or ask a developer to run the check queries in section 7).
5. S21 needs the sandbox-only alias record **"ACT Alias 89466" → "ACT Flow Only 89466"**.

| ID | Scenario | Expected |
|---|---|---|
| S1 | Company = TOS Account name | Converted onto that Account |
| S2 | No name match; Lead Assignment matched by email domain | Converted onto the flow's Account |
| S3 | Name match and a different flow match | Converted onto the **name** match |
| S4 | No match at all | Needs Manual Review: "No TOS Account matches … by name or alias, and the Lead Assignment flow found no matching Account." |
| S5 | Name matches only a Hospital Account | Needs Manual Review (non-TOS never counts) |
| S6 | Flow matched a non-TOS Account | Needs Manual Review: "…is not a TOS Account." |
| S7 | Lead lands in the California Leads queue | Converted; Contact and Opportunity owned by the **Account owner** |
| S8 | Contact with the same email already on the Account | Converted; **existing Contact reused** |
| S9 | Contact with the same email on another Account | Needs Manual Review: "A Contact with this email already exists on a different Account…" |
| S10 | Two Leads for the same Account | Both converted, in separate runs; project numbers `-100` and `-101` |
| S11 | TOS Lead created without MQL / Contact | Untouched (Not Contacted/New) |
| S12 | POS Lead with MQL / Contact | Untouched |
| S20 | Company "acct name, Inc." | Converted by **cleaned name** |
| S21 | Company equals an alias | Converted onto the alias's Account |
| S22 | Company "The acct name LLC" | Converted by **cleaned name** |
| S23 | Lead created **without** the stage, stage set within 5 minutes (HubSpot's late sync) | Picked up and processed |
| S24 | Lead created without the stage, stage set **after** 5 minutes | Untouched |
| S25 | Lead already processed, then edited again (another HubSpot sync) | Not processed a second time |

### What every converted Lead should show

- Lead Status **Qualified**, converted.
- Contact record type **General**, owner = Lead owner (or Account owner for queue Leads).
- Opportunity: record type **TOS**, stage **Proposed**, probability **50%**, Amount **$1**, close date **end of this
  month** if created on days 1–21 (else end of next month), **Principal Investigator** = the Contact,
  Created By **API User**, name like `99959-102 Account Name` (set by the existing naming flow).

### What every review Lead should show

- Status **Needs Manual Review**, not converted.
- A Task under Activity: "MQL Lead needs review: <name>", with the reason and a link.
- An email with the same content to the CC address (when email is on).

---

## 4. Manual tests without creating Leads (re-queue)

Changing an existing Lead's Status back to **Auto-Convert Pending** puts it through the automation again
without running Lead Assignment, so **no one else is emailed**. Use it for:

- **Review email:** leave a review Lead as it is, set Status to Auto-Convert Pending → it returns to review
  with a new Task and email to the CC.
- **Conversion:** first change **Company** to a TOS Account name (or a variant like "Name, Inc."), then set
  Status to Auto-Convert Pending → it converts.

The hourly check picks re-queued Leads up at the top of the hour. To run immediately, execute
`LeadAutoConvertWorker.requestStart('Manual test');` in Anonymous Apex.

Edit through the UI or Apex. A CLI/REST update (`sf data update record`) also runs Lead **assignment
rules** and can change the owner.

---

## 5. Edge tests

| Test | How | Expected |
|---|---|---|
| **Off switch** | Untick Active; create an MQL Lead; wait 90 s; tick Active again | Lead untouched. It is **not** picked up later when switched back on. |
| **Close date after cutoff** | Set Close Date Cutoff Day below today's date; convert one Lead; set back to 21 | Close date = end of **next** month |
| **Failure recovery** | Set Contact Record Type to a value that doesn't exist; re-queue 1–2 Leads; restore it | Runs fail, retry 10→5→2→1, Lead goes to review "Automatic conversion failed: …". After 5 failures in a row the chain stops (platform limit) and the hourly check carries on. |
| **Hourly safety net** | Leave a Lead in Auto-Convert Pending without starting the job | Processed at the next top of the hour |
| **Manual re-queue** | See section 4 | Converts or returns to review |
| **Volume** (not yet run) | Import ~500 MQL Leads (mix of matches, shared Accounts, no matches) with email on System only | All processed, no failed jobs, unique project numbers |

Change settings through the settings page, and put every value back afterwards.

---

## 6. Things that can't be tested in the sandbox

- **HubSpot → Salesforce sync.** HubSpot isn't connected to champsDev. In the sandbox, creating a Lead with
  `MQL / Contact` stands in for HubSpot. The real path needs a controlled production pilot (see
  [TESTING.md](TESTING.md) for the end-to-end checklist and the pre-pilot query).
- **Real user emails.** Sandbox user emails end in `.invalid`; use the Review Email CC.

---

## 7. Troubleshooting and useful queries

| Symptom | Check |
|---|---|
| Lead stays in Auto-Convert Pending | Report *Leads Waiting for Auto-Convert*; Setup → Apex Jobs for failed `LeadAutoConvertWorker` jobs; the trigger subscription status; that API User is active |
| Nothing happens to a new MQL Lead | Settings Active; flow active; stage was set **on create**; TOS record type |
| Opportunity failed | The review Task reason (e.g. a validation rule message) |
| Wrong owner | Lead Assignment set it; queue Leads take the Account owner |
| No review email | Deliverability; Review Email CC set; Setup → Email Log Files |

```sql
-- Leads waiting or in review
SELECT Id, Name, Company, Status, Owner.Name, LastModifiedDate FROM Lead
WHERE Status IN ('Auto-Convert Pending','Needs Manual Review') ORDER BY LastModifiedDate DESC

-- Recent worker runs (who it ran as, errors)
SELECT CreatedDate, Status, ExtendedStatus, CreatedBy.Name FROM AsyncApexJob
WHERE ApexClass.Name = 'LeadAutoConvertWorker' ORDER BY CreatedDate DESC LIMIT 10

-- What a converted Lead produced
SELECT ConvertedAccount.Name, ConvertedContact.Name, ConvertedOpportunity.Name,
       ConvertedOpportunity.StageName, ConvertedOpportunity.Amount, ConvertedOpportunity.CloseDate,
       ConvertedOpportunity.CreatedBy.Name, ConvertedOpportunity.Principal_Investigator__r.Name
FROM Lead WHERE Id = '<lead id>'
```

---

## 8. Clean-up

Test records are all named `ACT ...` with a tag (runs so far: `89466`, `82195`). After sign-off, delete those
Leads, Contacts, Opportunities and Accounts, and the sandbox-only alias **"ACT Alias 89466"**. Put
Deliverability and Review Email CC back to how the team wants them.
