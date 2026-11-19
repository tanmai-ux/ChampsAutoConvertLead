"""
HubSpot sync simulation for the MQL Lead auto-convert (sandbox only).

Mimics how the HubSpot connector writes to Salesforce: Leads created through the REST API in batches
(sObject Collections), the lifecycle stage sent on create or in a second update seconds later, re-syncs
of Leads already processed, and creates that Salesforce rejects as duplicates. Then checks every result.

Before running: sandbox Deliverability = System email only (Lead Assignment emails real people).
Usage:  python scripts/hubspot-sync-simulation.py [org alias, default champsDev]
Records are named "SYNC ... <tag>" so they're easy to find and delete.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

ORG = sys.argv[1] if len(sys.argv) > 1 else 'champsDev'
API = 'services/data/v62.0/'
SF = shutil.which('sf') or 'sf'
MQL = 'MQL / Contact'
TMP = tempfile.mkdtemp()
TAG = str(int(time.time()))[-5:]
START = time.time()


def log(msg):
    print(f'[{time.time() - START:6.1f}s] {msg}', flush=True)


def sf(args):
    out = subprocess.run([SF] + args, capture_output=True, text=True, encoding='utf-8')
    return out.stdout


def rest(path, method='GET', body=None):
    args = ['api', 'request', 'rest', API + path, '-o', ORG, '-X', method]
    if body is not None:
        f = os.path.join(TMP, 'body.json')
        with open(f, 'w', encoding='utf-8') as fh:
            json.dump(body, fh)
        args += ['-b', '@' + f]
    text = sf(args)
    return json.loads(text) if text.strip() else None


def query(soql):
    return rest('query?q=' + urllib.parse.quote(soql))['records']


def apex(code):
    f = os.path.join(TMP, 'run.apex')
    with open(f, 'w', encoding='utf-8') as fh:
        fh.write(code)
    for line in sf(['apex', 'run', '-o', ORG, '-f', f]).splitlines():
        if '|USER_DEBUG|' in line and 'OUT=' in line:
            return json.loads(line.split('OUT=', 1)[1])
    raise SystemExit('Apex setup failed')


def wait(seconds):
    time.sleep(seconds)


# ---------------------------------------------------------------- setup (Accounts, an existing Contact)
log(f'tag {TAG}: creating Accounts')
setup = apex(f"""
String tag = '{TAG}';
Id tos = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('TOS').getRecordTypeId();
Id hosp = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Hospital_Practice').getRecordTypeId();
Id owner = [SELECT Id FROM User WHERE Name = 'Earl Major' AND IsActive = TRUE LIMIT 1].Id;
Map<String, Account> a = new Map<String, Account>{{
    'A' => new Account(Name = 'SYNC Alpha ' + tag, RecordTypeId = tos, Account_Number__c = '95' + tag.right(2) + '1'),
    'B' => new Account(Name = 'SYNC Beta ' + tag, RecordTypeId = tos, Account_Number__c = '95' + tag.right(2) + '2'),
    'C' => new Account(Name = 'SYNC Gamma ' + tag, RecordTypeId = tos, Account_Number__c = '95' + tag.right(2) + '3'),
    'D' => new Account(Name = 'SYNC Delta ' + tag, RecordTypeId = tos, OwnerId = owner, Account_Number__c = '95' + tag.right(2) + '4'),
    'H' => new Account(Name = 'SYNC Hospital ' + tag, RecordTypeId = hosp)
}};
for (Integer i = 0; i < 10; i++) {{
    a.put('V' + i, new Account(Name = 'SYNC Volume ' + i + ' ' + tag, RecordTypeId = tos, Account_Number__c = '96' + tag.right(2) + i));
}}
insert a.values();
insert new Contact(FirstName = 'SYNC', LastName = 'Existing ' + tag, Email = 'sync.existing.' + tag + '@gmail.com',
    AccountId = a.get('A').Id,
    RecordTypeId = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName().get('General').getRecordTypeId());
Map<String, Object> out = new Map<String, Object>();
for (String k : a.keySet()) {{ out.put(k, new Map<String, Object>{{ 'id' => a.get(k).Id, 'name' => a.get(k).Name }}); }}
out.put('tosLead', Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName().get('TOS_Lead_Record_Type').getRecordTypeId());
out.put('earl', owner);
System.debug('OUT=' + JSON.serialize(out));
""")
ACC = {k: v for k, v in setup.items() if isinstance(v, dict)}
TOS_LEAD = setup['tosLead']
EARL = setup['earl']

# key -> (company, stage on create, state, expected) ; expected: ('convert', acct) | ('review',) | ('none',) | ('reject',)
CASES = {}
leads = {}  # key -> Id


def lead_body(key, company, stage, state='New York', email=None):
    return {
        'attributes': {'type': 'Lead'},
        'RecordTypeId': TOS_LEAD,
        'FirstName': 'SYNC',
        'LastName': f'{key} {TAG}',
        'Company': company,
        'Email': email or f'sync.{key.lower().replace(" ", "")}.{TAG}@gmail.com',
        'State': state,
        'Country': 'United States',
        'LeadSource': 'Web',
        'HubSpot_Lifecycle_Stage__c': stage,
    }


def create(batch):
    """batch: list of (key, body, expected). One sObject Collections call, like a HubSpot batch."""
    res = rest('composite/sobjects', 'POST', {'allOrNone': False, 'records': [b for _, b, _ in batch]})
    for (key, _, expected), r in zip(batch, res):
        CASES[key] = {'expected': expected, 'created': r.get('success'), 'errors': r.get('errors')}
        if r.get('success'):
            leads[key] = r['id']


def update(keys, fields):
    body = {'allOrNone': False, 'records': [dict({'attributes': {'type': 'Lead'}, 'id': leads[k]}, **fields) for k in keys]}
    return rest('composite/sobjects', 'PATCH', body)


name = lambda k: ACC[k]['name']

# ---------------------------------------------------------------- H1: one batch, stage set on create
log('H1: batch of 10 Leads with the stage on create')
create([
    ('H1a exact', lead_body('H1a exact', name('A'), MQL), ('convert', 'A')),
    ('H1b same acct', lead_body('H1b same acct', name('A'), MQL), ('convert', 'A')),
    ('H1c exact', lead_body('H1c exact', name('B'), MQL), ('convert', 'B')),
    ('H1d cleaned', lead_body('H1d cleaned', name('B').upper() + ', Inc.', MQL), ('convert', 'B')),
    ('H1e the llc', lead_body('H1e the llc', 'The ' + name('C') + ' LLC', MQL), ('convert', 'C')),
    ('H1f unmatched', lead_body('H1f unmatched', 'SYNC Nobody ' + TAG, MQL), ('review',)),
    ('H1g queue', lead_body('H1g queue', name('D'), MQL, state='California'), ('convert', 'D')),
    ('H1h hospital', lead_body('H1h hospital', name('H'), MQL), ('review',)),
    ('H1i wrong format', lead_body('H1i wrong format', name('A'), 'MQL/Contact'), ('none',)),
    ('H1j no stage', lead_body('H1j no stage', name('A'), None), ('none',)),
])

# ---------------------------------------------------------------- H2-H4: stage sent in a second update
log('H2-H4: Leads created without the stage (two-step sync)')
create([
    ('H2a late 20s', lead_body('H2a late 20s', name('B'), None), ('convert', 'B')),
    ('H2b late 20s', lead_body('H2b late 20s', 'SYNC Nobody Two ' + TAG, None), ('review',)),
    ('H2c late 20s', lead_body('H2c late 20s', name('C'), None), ('convert', 'C')),
    ('H3 late 80s', lead_body('H3 late 80s', name('C'), None), ('none',)),
    ('H4 lead then mql', lead_body('H4 lead then mql', name('D'), 'Lead'), ('convert', 'D')),
])
t_created = time.time()

# ---------------------------------------------------------------- H6: creates Salesforce rejects
log('H6: email already on a Contact (allowed) / on a Lead (rejected)')
create([
    ('H6a contact email', lead_body('H6a contact email', name('A'), MQL, email=f'sync.existing.{TAG}@gmail.com'), ('convert', 'A')),
    ('H6b dup lead', lead_body('H6b dup lead', name('B'), MQL, email=f'sync.h1cexact.{TAG}@gmail.com'), ('reject',)),
])

# ---------------------------------------------------------------- H7: large batch
log('H7: batch of 50 Leads across 10 Accounts')
create([(f'H7 v{i}-{j}', lead_body(f'H7 v{i}-{j}', name(f'V{i}'), MQL), ('convert', f'V{i}'))
        for i in range(10) for j in range(5)])

wait(max(0, 20 - (time.time() - t_created)))
log('H2/H4: second update sets the stage (~20 s after create)')
update(['H2a late 20s', 'H2b late 20s', 'H2c late 20s', 'H4 lead then mql'], {'HubSpot_Lifecycle_Stage__c': MQL})

wait(max(0, 80 - (time.time() - t_created)))
log('H3: stage sent 80 s after create (outside the 1-minute window)')
update(['H3 late 80s'], {'HubSpot_Lifecycle_Stage__c': MQL})

# ---------------------------------------------------------------- wait for the worker
ids = "','".join(leads.values())
for _ in range(40):
    pending = query(f"SELECT Id FROM Lead WHERE Id IN ('{ids}') AND Status = 'Auto-Convert Pending'")
    log(f'waiting: {len(pending)} pending')
    if not pending:
        break
    wait(15)

# ---------------------------------------------------------------- H5: HubSpot re-syncs processed Leads
log('H5: re-sync of a review Lead and a converted Lead')
tasks_before = len(query(f"SELECT Id FROM Task WHERE WhoId = '{leads['H1f unmatched']}'"))
resync_review = update(['H1f unmatched'], {'Title': 'Re-synced', 'HubSpot_Lifecycle_Stage__c': MQL})
resync_converted = update(['H1a exact'], {'Title': 'Re-synced'})
wait(30)

# ---------------------------------------------------------------- check
rows = {r['Id']: r for r in query(
    "SELECT Id, LastName, Status, IsConverted, OwnerId, ConvertedAccountId, ConvertedContact.OwnerId, "
    "ConvertedContact.Name, ConvertedContact.RecordType.DeveloperName, ConvertedOpportunity.Name, ConvertedOpportunity.StageName, "
    "ConvertedOpportunity.Amount, ConvertedOpportunity.RecordType.DeveloperName, ConvertedOpportunity.CreatedBy.Name, "
    "ConvertedOpportunity.Principal_Investigator__c, ConvertedContactId "
    f"FROM Lead WHERE Id IN ('{ids}')")}
task_count = {}
for t in query(f"SELECT WhoId FROM Task WHERE WhoId IN ('{ids}')"):
    task_count[t['WhoId']] = task_count.get(t['WhoId'], 0) + 1

results, opp_names = [], []
for key, case in CASES.items():
    exp = case['expected']
    if exp[0] == 'reject':
        codes = [e.get('statusCode') for e in case['errors'] or []]
        ok = not case['created']
        results.append((key, ok, 'rejected: ' + ', '.join(codes) if ok else 'was created'))
        continue
    if not case['created']:
        results.append((key, False, 'create failed: ' + json.dumps(case['errors'])))
        continue
    r = rows[leads[key]]
    if exp[0] == 'convert':
        o = r.get('ConvertedOpportunity') or {}
        problems = []
        if not r['IsConverted']:
            problems.append('not converted (' + r['Status'] + ')')
        else:
            if r['ConvertedAccountId'] != ACC[exp[1]]['id']:
                problems.append('wrong Account')
            if (o.get('StageName'), o.get('Amount'), (o.get('RecordType') or {}).get('DeveloperName')) != ('Proposed', 1.0, 'TOS'):
                problems.append(f"opp {o.get('StageName')} {o.get('Amount')}")
            if (o.get('CreatedBy') or {}).get('Name') != 'API User':
                problems.append('not created by API User')
            if o.get('Principal_Investigator__c') != r['ConvertedContactId']:
                problems.append('PI not set')
            if r['ConvertedContact']['RecordType']['DeveloperName'] != 'General':
                problems.append('contact record type')
            if key == 'H6a contact email' and not r['ConvertedContact']['Name'].startswith('SYNC Existing'):
                problems.append('existing Contact not reused')
            if key == 'H1g queue' and r['ConvertedContact']['OwnerId'] != EARL:
                problems.append('queue Lead not owned by the Account owner')
            opp_names.append(o.get('Name'))
        results.append((key, not problems, '; '.join(problems) or 'converted: ' + o.get('Name', '')))
    elif exp[0] == 'review':
        ok = r['Status'] == 'Needs Manual Review' and task_count.get(r['Id'], 0) == 1
        results.append((key, ok, f"{r['Status']}, {task_count.get(r['Id'], 0)} Task(s)"))
    else:
        ok = not r['IsConverted'] and r['Status'] == 'Not Contacted/New'
        results.append((key, ok, r['Status']))

dupes = {n for n in opp_names if opp_names.count(n) > 1}
results.append(('Unique Opportunity numbers', not dupes, ', '.join(dupes) or f'{len(opp_names)} unique'))
r = rows[leads['H1f unmatched']]
results.append(('H5 re-sync of review Lead', resync_review[0]['success'] and r['Status'] == 'Needs Manual Review'
                and task_count.get(r['Id'], 0) == tasks_before,
                f"update ok={resync_review[0]['success']}, {r['Status']}, Tasks {tasks_before} -> {task_count.get(r['Id'], 0)}"))
results.append(('H5 re-sync of converted Lead', not resync_converted[0]['success'],
                'rejected: ' + ', '.join(e['statusCode'] for e in resync_converted[0].get('errors') or [])
                if not resync_converted[0]['success'] else 'update was accepted'))

passed = sum(1 for _, ok, _ in results if ok)
print(f'\nTag {TAG}: {passed}/{len(results)} checks passed\n')
for key, ok, detail in results:
    print(f"{'PASS' if ok else 'FAIL'}  {key:28} {detail}")
with open(os.path.join(TMP, 'leads.json'), 'w') as fh:
    json.dump(leads, fh)
print('\nLead Ids:', os.path.join(TMP, 'leads.json'))
