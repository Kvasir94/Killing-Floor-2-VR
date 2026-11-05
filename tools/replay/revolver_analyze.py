"""Audit real occupied-hand cylinder observations and paid replacement or stock deficit payment."""
import re
from ammo_payload_analyze import fields
from weapons import weapon_path


def analyze(text, case):
    errors, paths, ledgers, callbacks, stack, calls = [], [], [], [], [], set()
    replacement = bool(case.get('lose_ammo'))
    policy = 'paid-replacement' if replacement else 'stock-deficit-top-up'
    if replacement and not case.get('recover_mags'):
        errors.append('Recovery-off cylinder discard accounting is unsupported')
    for order, line in enumerate(text.splitlines()):
        marker = next((m for m in ('KF2VR_REVOLVER_PATH ', 'KF2VR_REVOLVER_LEDGER ', 'KF2VR_RELOAD_CALLBACK ') if m in line), None)
        if marker is None: continue
        row = fields(line, marker, errors); row['_order'] = order
        if row.get('case') != case['lifecycle_case']: errors.append('Selected cylinder path mismatch')
        target = paths if marker == 'KF2VR_REVOLVER_PATH ' else ledgers if marker == 'KF2VR_REVOLVER_LEDGER ' else callbacks
        target.append(row)
        if row.get('seq') != str(len(target)): errors.append('Missing or duplicate ordered observations')
        if target is not callbacks:
            if target is paths and (row.get('optionEffect') != 'ammo-loss' or row.get('reloadPolicy') != policy
                    or any(row.get(k) != str(case[v]) for k,v in (('keep','keep_chamber'),('lose','lose_ammo'),('recover','recover_mags')))):
                errors.append('Cylinder policy/profile mismatch')
            continue
        if row.get('source') != 'production': errors.append('Callback source is not production')
        if row.get('phase') == 'before':
            if not re.fullmatch(r'[1-9]\d*',row.get('call','')) or row.get('call') in calls:
                errors.append('Invalid or repeated callback invocation')
            calls.add(row.get('call')); stack.append(row)
        elif row.get('phase') == 'after' and stack:
            before = stack.pop()
            if any(before.get(k) != row.get(k) for k in ('call','function','weapon','action','receipt')):
                errors.append('Unbalanced production callback identity')
        else: errors.append('Callback return without matching invocation')
    if stack: errors.append('Missing callback return')
    initial = [r for r in paths if r.get('phase') == 'initial']
    terminal = [r for r in paths if r.get('phase') == 'complete']
    if (len(terminal) != 1 or not paths or paths[-1] != terminal[0] or terminal[0].get('passed') != 'True'
            or terminal[0].get('reason') != 'real-revolver-hip-completed'):
        errors.append('Missing successful final cylinder outcome')
    hands = ['0','1'] if case['case'] == 'dual' else ['1']
    if sorted(r.get('hand','') for r in initial) != hands: errors.append('Missing exact initial cylinder hands')
    totals = dict(initial=0, final=0, shots=0, escrow=0, payment=0)
    initial_reserves, final_reserves, owners = set(), set(), set()
    for start in initial:
        hand, weapon = start.get('hand'), start.get('weapon')
        rows = [r for r in paths if r.get('hand') == hand]
        if not weapon or '.' not in weapon: errors.append('Missing cylinder actor identity')
        if (start.get('selectedClass','').lower() != weapon_path(case['weapon']).lower()
                or start.get('selectedFamilyClass','').lower() != start.get('pairSingleClass','').lower()
                or not start.get('pairSingleClass') or start.get('pairSingleClass') == 'None'):
            errors.append('Selected production cylinder family mismatch')
        if case['case'] == 'normal' and start.get('weaponClass','').lower() != weapon_path(case['weapon']).lower():
            errors.append('Selected single cylinder class mismatch')
        if case['case'] == 'dual':
            owners.add(start.get('pairOwner'))
            if start.get('pairOwner') in (None,'None') or start.get('pairedClass') in (None,'None'):
                errors.append('Missing actual paired owner/class')
        if any(r.get(k) != start.get(k) or start.get(k) in (None,'None','') for r in rows for k in
               ('weapon','pawn','world','ownership','selectedClass','selectedFamilyClass','pairSingleClass','memberClass')):
            errors.append('Cylinder identity/ownership changed or missing')
        stages={}
        for phase in ('initial','admitted','opened','contact','closing','paid','settled','retry'):
            found=[r for r in rows if r.get('phase') == phase]
            if len(found) != 1: errors.append('Need exactly one '+phase+' per cylinder')
            else: stages[phase]=found[0]
        shots=[r for r in rows if r.get('phase') == 'shot']
        if len(stages) != 8 or not shots: errors.append('Incomplete finite cylinder path'); continue
        ordered=[stages['initial']]+shots+[stages[k] for k in ('admitted','opened','contact','closing','paid','settled','retry')]
        if ordered != sorted(ordered,key=lambda r:r['_order']): errors.append('Misordered cylinder completion path')
        contacts=[r for r in callbacks if r.get('phase') == 'after' and r.get('accepted') == 'True'
                  and r.get('weapon') == weapon and r.get('function') == 'KF2VR.VRCylinderSession.Tick' and r.get('boundary') == 'seat-contact']
        payments=[r for r in callbacks if r.get('phase') == 'after' and r.get('accepted') == 'True'
                  and r.get('weapon') == weapon and r.get('function') == 'KF2VR.VRCylinderSession.Complete']
        if len(contacts) != 1 or len(payments) != 1: errors.append('Need one actual hip contact and payment'); continue
        contact,payment=contacts[0],payments[0]
        if (contact.get('hip') != 'True' or contact.get('hand') != hand or contact.get('call') != stages['contact'].get('call')
                or payment.get('call') != stages['paid'].get('call') or not contact['_order'] < payment['_order'] < stages['settled']['_order']):
            errors.append('Missing ordered matching contact/payment callbacks')
        if payment.get('receipt') != stages['admitted'].get('paymentRequest'):
            errors.append('Paid request differs from admitted cylinder transaction')
        if case['case'] == 'dual':
            if not re.fullmatch(r'[1-9]\d*',payment.get('receipt','')) or not re.fullmatch(r'[1-9]\d*',stages['admitted'].get('paymentSession','')):
                errors.append('Missing real paired request/session')
            if stages['retry'].get('authorityStatus') != '2': errors.append('Full retry changed paid authority status')
        elif payment.get('receipt') != '0' or payment.get('synchronous') != 'True': errors.append('Missing synchronous stock payment identity')
        try:
            ammo=int(start['loaded']); spent=0; capacity=int(start['capacity'])
            for shot in shots:
                debit=int(shot['rounds'])
                if debit <= 0 or int(shot['loaded']) != ammo-debit: errors.append('Cylinder shot delta mismatch')
                spent+=debit; ammo=int(shot['loaded'])
            if (any(int(stages[p]['loaded']) != capacity for p in ('paid','settled','retry'))
                    or int(payment['loaded']) != capacity or int(stages['retry']['firedRounds']) != spent
                    or int(stages['retry']['reserve']) != int(stages['settled']['reserve'])
                    or int(payment['reserve']) != int(stages['settled']['reserve'])):
                errors.append('Stock deficit payment or settled ammunition mismatch')
            if int(stages['admitted']['loaded']) != ammo or any(int(stages[p]['loaded']) != (0 if replacement else ammo) for p in ('opened','contact','closing')):
                errors.append('Old cylinder debit does not match the selected loss policy')
            totals['initial']+=int(start['loaded']); totals['final']+=capacity; totals['shots']+=spent
            totals['escrow'] += ammo if replacement else 0
            totals['payment'] += capacity if replacement else capacity-ammo
            initial_reserves.add(int(start['reserve'])); final_reserves.add(int(stages['retry']['reserve']))
        except (KeyError,ValueError): errors.append('Missing observed cylinder accounting')
        if (stages['retry'].get('nativeRetrySeen') != 'True' or stages['retry'].get('stable') != 'True'
                or stages['retry'].get('rejected') != 'True' or stages['retry'].get('physicalActive') != 'False'
                or stages['retry'].get('bridgeRequestSerial') != stages['settled'].get('bridgeRequestSerial')):
            errors.append('Missing stable real full-cylinder retry rejection')
    if case['case'] == 'dual' and (len(owners) != 1 or len({r.get('weapon') for r in initial}) != 2):
        errors.append('Distinct members of the same real pair required')
    if len(paths) != len(ledgers) or any(a.get('seq') != b.get('seq') or a.get('phase') != b.get('phase') for a,b in zip(paths,ledgers)):
        errors.append('Missing matching actual ledger snapshots')
    baseline=None
    for row in ledgers:
        try:
            numbers=[int(row[k]) for k in ('loaded','reserve','shots','escrow','tokens','mismatch')]
            total=sum(numbers[:4])
            if baseline is None: baseline=total
            if min(numbers)<0 or numbers[5] or total!=baseline or (numbers[3]>0 and numbers[4]==0):
                errors.append('Cylinder authority conservation failed')
        except (KeyError,ValueError): errors.append('Invalid authority ledger count')
    try:
        if (len(initial_reserves)!=1 or len(final_reserves)!=1 or not ledgers
                or int(ledgers[0]['loaded'])!=totals['initial'] or int(ledgers[0]['reserve']) not in initial_reserves
                or int(ledgers[0]['shots'])!=0 or int(ledgers[-1]['loaded'])!=totals['final']
                or int(ledgers[-1]['reserve']) not in final_reserves or int(ledgers[-1]['shots'])!=totals['shots']
                or int(ledgers[0]['escrow'])!=0 or int(ledgers[0]['tokens'])!=0
                or int(ledgers[-1]['escrow'])!=totals['escrow']
                or (totals['escrow']>0 and int(ledgers[-1]['tokens'])<len(hands))
                or next(iter(initial_reserves))-next(iter(final_reserves))!=totals['payment']):
            errors.append('Actual ledgers do not match observed cylinder actors')
    except (KeyError,ValueError): errors.append('Incomplete cross-linked cylinder ledger')
    if re.search(r'ScriptWarning:|ScriptError:|Critical:|Fatal error|Accessed None',text): errors.append('Runtime warning or error')
    return dict(bounded_case_passed=not errors,errors=list(dict.fromkeys(errors)),geometry_rows=len(paths),
                callback_rows=len(callbacks),ledger_rows=len(ledgers),coverage='observed-cylinder-shot-open-hip-close-stock-payment-full-retry',
                full_reload_accepted=False,headset_accepted=False,multiplayer_accepted=False)
