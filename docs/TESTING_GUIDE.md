# QA Test Guide – MQL Lead Auto-Convert

Sandbox: **champsDev**. Use this guide to check that new MQL Leads convert automatically, or go to review
when they can't. Past results: [TESTING.md](TESTING.md).

---

## 1. What you're testing (in one minute)

When a **TOS Lead** arrives with **HubSpot Lifecycle Stage = `MQL / Contact`**, Salesforce should, within about
a minute:

- **Convert it** into a Contact and an Opportunity on the matching **TOS Account**, or
- **Send it to review**: Status **Needs Manual Review**, plus a Task (and email) telling the owner why.

The Account is matched by the Lead's **Company** (exact name, or the name ignoring "Inc", "LLC",
punctuation and "The"), an admin **alias**, or Lead Assignment's email-domain match.

---

## 2. Before you start

| # | Check | How |
|---|---|---|
| 1 | **Turn email off** (important) | Setup → Deliverability → **System email only**. Creating a Lead makes the existing Lead Assignment flow email **real people** (Tim Cates, Colleen Jennings, regional teams). |
| 2 | Automation is on | Setup → Custom Metadata Types → Lead Auto Convert Setting → Manage → **Default**: **Active** ticked |
| 3 | You can edit HubSpot Lifecycle Stage | Only admins can. Log in as an admin. |
| 4 | Test Accounts exist | Use these TOS Accounts (already in the sandbox): **ACT Shared 82195**, **ACT Clean Target 82195**, **ACT Contact Reuse 82195**, **ACT Other Company 82195**, **ACT Hospital 82195** (Hospital type – should never be used) |

---

## 3. How to create a test Lead

1. App Launcher → **Leads** → **New** → record type **TOS Lead Record Type**.
2. Fill in **First / Last Name** (start the last name with `QA` so it's easy to find later), **Company**, **Email**
   (use a made-up address, e.g. `qa1@example.com`), **Country** United States, **State** New York.
3. Set **HubSpot Lifecycle Stage** to `MQL / Contact` (unless the test says otherwise).
4. **Save**, wait **1 minute**, then **refresh** the page.

## 4. How to check the result

| If it converted | If it went to review |
|---|---|
| The Lead shows as converted (or opens the new records) | Status = **Needs Manual Review** |
| **Account** → Contacts: the new Contact (record type General) | Activity → a Task **"MQL Lead needs review: …"** with the reason |
| **Account** → Opportunities: a new one with Stage **Proposed**, Probability **50%**, Amount **$1**, record type **TOS**, Close Date **end of this month** (created days 1–21) or **end of next month** (day 22+), **Principal Investigator** = the Contact, Created By **API User** | Email to the Review Email CC address (only when email is on) |

---

## 5. Test cases

Record **Pass / Fail** for each. "Create a Lead" means section 3.

| ID | What you're testing | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|
| QA-01 | Exact name match | Create a Lead, Company **ACT Shared 82195** | Converts onto **ACT Shared 82195**; Opportunity named with the next number, e.g. `99959-1xx ACT Shared 82195` | |
| QA-02 | Name with "Inc" / different capitals | Company **act clean target 82195, Inc.** | Converts onto **ACT Clean Target 82195** | |
| QA-03 | Name with "The" and "LLC" | Company **The ACT Clean Target 82195 LLC** | Converts onto **ACT Clean Target 82195** | |
| QA-04 | No match | Company **QA Nobody Company** | **Needs Manual Review**; Task reason "No TOS Account matches …" | |
| QA-05 | Only a non-TOS Account matches | Company **ACT Hospital 82195** | **Needs Manual Review** (Hospital Accounts don't count) | |
| QA-06 | Existing Contact on the same Account | First create a **Contact** on **ACT Contact Reuse 82195** (record type General, email `qa-reuse@example.com`). Then create a Lead: Company **ACT Contact Reuse 82195**, Email `qa-reuse@example.com` | Converts and **reuses that Contact** (no second Contact) | |
| QA-07 | Email belongs to a Contact on another Account | First create a **Contact** on **ACT Other Company 82195** (email `qa-other@example.com`). Then create a Lead: Company **ACT Shared 82195**, Email `qa-other@example.com` | **Needs Manual Review**; reason "A Contact with this email already exists on a different Account" | |
| QA-08 | Lead lands in a regional queue | Company **ACT Shared 82195**, **State California** | Converts; Contact and Opportunity owned by the **Account owner** (not the queue) | |
| QA-09 | Two Leads for the same Account | Create two Leads quickly, both Company **ACT Shared 82195** | Both convert; their Opportunities get **different numbers** | |
| QA-10 | Not an MQL | Company **ACT Shared 82195**, HubSpot Lifecycle Stage **blank** | **Nothing happens** (stays Not Contacted/New) | |
| QA-11 | POS Lead | Record type **POS**, Company **ACT Shared 82195**, stage `MQL / Contact` | **Nothing happens** | |
| QA-12 | Stage arrives late (HubSpot's second sync) | Create a Lead **without** the stage; within **1 minute** (about 15-30 seconds) edit it and set `MQL / Contact` | Converts (picked up after the edit) | |
| QA-13 | Stage arrives too late | Create a Lead without the stage; **wait 2 minutes**; then set `MQL / Contact` | **Nothing happens**; the Lead appears in the *MQL Leads Not Picked Up* report | |
| QA-14 | Edit after processing | Take the QA-04 Lead (in review); edit another field (e.g. Title) and save | Stays in review; **no** second Task | |
| QA-15 | Retry after fixing | Take the QA-04 Lead; change Company to **ACT Shared 82195** and Status to **Auto-Convert Pending**; save | Converts at the next **top of the hour** (hourly check) | |
| QA-16 | Review email | Turn email **on** (All email), put your address in **Review Email CC**; set a review Lead's Status to **Auto-Convert Pending** and wait for the top of the hour | Lead returns to review; you receive "MQL Lead needs review: …" from no-reply@championsoncology.com | |
| QA-17 | Off switch | Untick **Active**; create a Lead like QA-01; wait 2 minutes; tick **Active** again | **Nothing happens** to that Lead (it is not picked up later either) | |

Tips:

- Use a **new email address for every Lead** – the duplicate rules block a second Lead with the same email.
- QA-15 and QA-16 wait for the hourly check. A developer can start it immediately (appendix).
- For QA-16 only: creating Leads with email on emails real people, so use an existing Lead as described.
- Put **Active**, **Review Email CC** and **Deliverability** back how the team wants them when you finish.

---

## 6. Monitoring reports

Reports → folder **Lead Auto Convert**:

- **MQL Lead Outcomes** – every TOS MQL Lead grouped by what happened: Qualified (converted), Needs Manual
  Review, Auto-Convert Pending (waiting), Not Contacted/New (never picked up). Filter by Created Date after an import.
- **Leads Waiting for Auto-Convert** – should be empty, or only minutes old. Anything older means something is stuck.
- **MQL Leads Needing Manual Review** – Leads waiting for a rep, oldest first.
- **MQL Leads Not Picked Up** – MQL Leads the automation never touched (for example HubSpot sent the stage more
  than 1 minute after creating the Lead, or auto-convert was off). Convert them by hand or re-queue them.

## 7. Not testable in the sandbox

- **The real HubSpot sync** only works where HubSpot is connected (production, or a connected sandbox). In
  this guide, creating a Lead with `MQL / Contact` stands in for HubSpot.
- **Emails to real users:** sandbox user emails end in `.invalid`; use **Review Email CC** to see review emails.

## 8. Clean-up

Delete your `QA …` Leads and any Contacts/Opportunities they created when testing is signed off.

---

## Appendix – for developers

- **Apex tests (39):**
  `sf apex run test -o champsDev -n LeadAutoConvertServiceTest -n LeadAutoConvertWorkerTest -n LeadAutoConvertAccountMatcherTest -w 20`
- **Full scripted run:** `sf apex run -o champsDev -f scripts/apex/lead-auto-convert-scenarios.apex` (email off first).
- **Start the job now** (instead of waiting for the hourly check): Anonymous Apex `LeadAutoConvertWorker.requestStart('QA');`
- **The flow's 1-minute rule can't be unit tested** (async flow paths don't run in Apex tests) – QA-12/13 cover it.
- **Edits from the CLI/REST API** run Lead assignment rules and can change the owner; use the UI or Apex.
- **Useful queries:**

```sql
SELECT Id, Name, Company, Status, Owner.Name, LastModifiedDate FROM Lead
WHERE Status IN ('Auto-Convert Pending','Needs Manual Review') ORDER BY LastModifiedDate DESC

SELECT CreatedDate, Status, ExtendedStatus, CreatedBy.Name FROM AsyncApexJob
WHERE ApexClass.Name = 'LeadAutoConvertWorker' ORDER BY CreatedDate DESC LIMIT 10
```
