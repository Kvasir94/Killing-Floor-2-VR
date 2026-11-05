"""Audit observed generic magazine paths; never manufacture gameplay results."""
import math
import re

from ammo_payload_analyze import fields


def analyze(text, case):
    errors, paths, callbacks, ledgers, stack, calls = [], [], [], [], [], set()
    for order, line in enumerate(text.splitlines()):
        marker = next((m for m in ('KF2VR_MAGAZINE_PATH ', 'KF2VR_MAGAZINE_LEDGER ',
                                   'KF2VR_RELOAD_CALLBACK ') if m in line), None)
        if marker is None:
            continue
        row = fields(line, marker, errors)
        row['_order'] = order
        if row.get('case') != case['lifecycle_case']:
            errors.append('Selected path identity mismatch')
        if marker == 'KF2VR_MAGAZINE_PATH ':
            paths.append(row)
            if row.get('seq') != str(len(paths)):
                errors.append('Missing or duplicate path sequence')
            if any(row.get(k) != str(case[v]) for k, v in
                   (('keep', 'keep_chamber'), ('lose', 'lose_ammo'), ('recover', 'recover_mags'))):
                errors.append('Observed option profile mismatch')
            try:
                if not math.isfinite(float(row['time'])) or (len(paths) > 1 and float(row['time']) < float(paths[-2]['time'])):
                    raise ValueError()
            except (KeyError, ValueError):
                errors.append('Invalid path time')
        elif marker == 'KF2VR_MAGAZINE_LEDGER ':
            ledgers.append(row)
        else:
            callbacks.append(row)
            if row.get('source') != 'production' or row.get('seq') != str(len(callbacks)):
                errors.append('Missing ordered production callback')
            if row.get('phase') == 'before':
                if not re.fullmatch(r'[1-9]\d*', row.get('call', '')) or row.get('call') in calls:
                    errors.append('Duplicate or invalid callback invocation')
                calls.add(row.get('call')); stack.append(row)
            elif row.get('phase') == 'after' and stack:
                before = stack.pop()
                if any(before.get(k) != row.get(k) for k in ('call', 'function', 'weapon', 'action', 'receipt')):
                    errors.append('Unbalanced callback identity')
            else:
                errors.append('Callback return without invocation')
    if stack:
        errors.append('Missing production callback return')
    ends = [r for r in paths if r.get('phase') == 'complete']
    if (len(ends) != 1 or not paths or paths[-1] != ends[0] or ends[0].get('passed') != 'True'
            or ends[0].get('reason') != 'real-magazine-hip-completed'):
        errors.append('Missing successful final magazine outcome')
    initial = [r for r in paths if r.get('phase') == 'initial']
    hands = ['0', '1'] if case['case'] == 'dual' else ['1']
    if sorted(r.get('hand', '') for r in initial) != hands:
        errors.append('Missing exact initial weapon hands')
    after = [r for r in callbacks if r.get('phase') == 'after' and r.get('accepted') == 'True']
    initial_loaded = final_loaded = shot_total = expected_escrow = 0
    initial_reserves, final_reserves = set(), set()
    for start in initial:
        hand, weapon = start.get('hand'), start.get('weapon')
        if not weapon or '.' not in weapon or start.get('authoredInput') != 'True' or start.get('measuredHumanInput') != 'False':
            errors.append('Missing real actor identity and declared authored input')
        rows = [r for r in paths if r.get('hand') == hand]
        stages = {}
        for phase in ('initial', 'removal', 'contact', 'seated', 'retry'):
            found = [r for r in rows if r.get('phase') == phase]
            if len(found) != 1:
                errors.append('Need exactly one '+phase+' for hand '+str(hand))
            else:
                stages[phase] = found[0]
        shots = [r for r in rows if r.get('phase') == 'shot']
        if not shots or len(stages) != 5:
            errors.append('Incomplete shot/removal/contact/payment path'); continue
        ordered = [stages['initial']] + shots + [stages[k] for k in ('removal', 'contact', 'seated', 'retry')]
        if ordered != sorted(ordered, key=lambda r: r['_order']):
            errors.append('Misordered real magazine path')
        if any(r.get('weapon') != weapon for r in rows):
            errors.append('Weapon changed within a path')
        if any(r.get(k) != start.get(k) or not start.get(k) for r in rows for k in ('pawn', 'world', 'ownership')):
            errors.append('Pawn/world/ownership changed or missing')
        from weapons import weapon_path
        selected_class = weapon_path(case['weapon']).rsplit('.', 1)[-1]
        if case['case'] == 'normal' and not re.search(r'\.'+re.escape(selected_class)+r'_\d+$', weapon, re.I):
            errors.append('Selected weapon class was not observed')
        if case['case'] == 'dual':
            if (start.get('selectedClass', '').lower() != weapon_path(case['weapon']).lower()
                    or start.get('selectedFamilyClass', '').lower() != start.get('pairSingleClass', '').lower()
                    or not start.get('pairSingleClass') or start.get('pairOwner') in (None, 'None')
                    or start.get('pairedClass') in (None, 'None')
                    or not weapon.lower().rsplit('.', 1)[-1].startswith(start.get('memberClass', '').lower().rsplit('.', 1)[-1]+'_')):
                errors.append('Selected paired family/member identity was not observed')
            if any(r.get(k) != start.get(k) for r in rows for k in
                   ('selectedClass', 'selectedFamilyClass', 'pairSingleClass', 'memberClass', 'pairedClass', 'pairOwner')):
                errors.append('Paired family/owner changed within a path')
        remove = [r for r in after if r.get('weapon') == weapon and r.get('function') == 'KF2VR.VRMagazineAuthority.Remove']
        contact = [r for r in after if r.get('weapon') == weapon and r.get('function') == 'KF2VR.VRCylinderSession.Tick' and r.get('boundary') == 'seat-contact']
        paid = [r for r in after if r.get('weapon') == weapon and r.get('function') == 'KF2VR.VRCylinderSession.Complete']
        if any(len(v) != 1 for v in (remove, contact, paid)):
            errors.append('Need exactly one accepted removal/contact/payment per weapon'); continue
        remove, contact, paid = remove[0], contact[0], paid[0]
        token = stages['removal'].get('request', '')
        if not re.fullmatch(r'[1-9]\d*', token) or remove.get('receipt') != token:
            errors.append('Removal receipt does not match actual removal request')
        if any(r.get('request') != token for r in rows if r['_order'] >= stages['removal']['_order']):
            errors.append('Removal identity changed or duplicated')
        if (contact.get('hip') != 'True' or contact.get('hand') != hand
                or not (remove['_order'] < contact['_order'] < paid['_order'] < stages['seated']['_order'])):
            errors.append('Missing ordered real hip contact and payment')
        if paid.get('receipt') == '0':
            if case['case'] != 'normal' or paid.get('synchronous') != 'True' or paid.get('boundary') != 'single-payment':
                errors.append('Unidentified synchronous payment')
        elif not re.fullmatch(r'[1-9]\d*', paid.get('receipt', '')):
            errors.append('Missing authority payment request')
        try:
            initial_ammo, capacity = int(start['loaded']), int(start['capacity'])
            post_shot = initial_ammo
            rounds = 0
            for shot in shots:
                spent = int(shot['rounds'])
                if spent <= 0 or int(shot['loaded']) != post_shot-spent:
                    errors.append('Shot delta does not match actual ammunition')
                post_shot = int(shot['loaded']); rounds += spent
            kept = min(post_shot, int(start['chamberRounds'])) if (case['keep_chamber']
                    and start.get('tracksFeed') == 'True' and start.get('hasChamber') == 'True') else 0
            payload = post_shot-kept if case['lose_ammo'] else 0
            if (int(stages['removal']['loaded']) != kept or int(stages['removal']['chamberKept']) != kept
                    or int(stages['removal']['payload']) != payload or int(remove['actual']) != payload
                    or int(remove['remaining']) != payload):
                errors.append('Chamber retention or removed payload contradicts selected policy')
            if (int(stages['seated']['loaded']) != capacity+kept
                    or int(stages['seated']['fullExpected']) != capacity+kept
                    or int(stages['retry']['firedRounds']) != rounds):
                errors.append('Full magazine or observed shot accounting mismatch')
            initial_loaded += initial_ammo; final_loaded += int(stages['retry']['loaded'])
            shot_total += rounds; expected_escrow += payload
            initial_reserves.add(int(start['reserve'])); final_reserves.add(int(stages['retry']['reserve']))
            if int(paid['loaded']) != int(stages['seated']['loaded']) or int(stages['retry']['loaded']) != int(stages['seated']['loaded']):
                errors.append('Paid ammunition does not match settled/retry state')
            if int(paid['reserve']) != int(stages['seated']['reserve']) or stages['retry']['reserve'] != stages['seated']['reserve']:
                errors.append('Payment/reserve changed after completion')
        except (KeyError, ValueError):
            errors.append('Missing observed paid ammunition')
        if stages['retry'].get('stable') != 'True' or stages['retry'].get('rejected') != 'True':
            errors.append('Missing native full-mag retry rejection')
    if len(ledgers) != len(paths) or any(a.get('seq') != b.get('seq') or a.get('phase') != b.get('phase') for a, b in zip(paths, ledgers)):
        errors.append('Missing matching actual ledger snapshots')
    baseline = None
    for row in ledgers:
        try:
            counts = [int(row[k]) for k in ('loaded', 'reserve', 'escrow', 'shots', 'tokens', 'mismatch')]
            if min(counts) < 0 or counts[-1]:
                raise ValueError()
            total = sum(counts[:4])
            if baseline is None: baseline = total
            if total != baseline: errors.append('Actual ledger conservation failed')
        except (KeyError, ValueError):
            errors.append('Invalid observed ledger count')
    if not ledgers:
        errors.append('No actual authority ledger observations')
    else:
        try:
            first, last = ledgers[0], ledgers[-1]
            if (len(initial_reserves) != 1 or len(final_reserves) != 1
                    or int(first['loaded']) != initial_loaded or int(first['reserve']) not in initial_reserves
                    or any(int(first[k]) for k in ('escrow', 'shots', 'tokens'))
                    or int(last['loaded']) != final_loaded or int(last['reserve']) not in final_reserves
                    or int(last['shots']) != shot_total or int(last['escrow']) != expected_escrow):
                errors.append('Ledger snapshots do not match observed weapons/reserve/shots/payloads')
        except (KeyError, ValueError):
            errors.append('Missing cross-linked initial/final ledger counts')
    if re.search(r'ScriptWarning:|ScriptError:|Critical:|Fatal error|Accessed None', text):
        errors.append('Runtime warning or error')
    return dict(bounded_case_passed=not errors, errors=list(dict.fromkeys(errors)),
                geometry_rows=len(paths), callback_rows=len(callbacks), ledger_rows=len(ledgers),
                coverage='observed-shot-removal-chamber-hip-seat-payment-full-retry',
                full_reload_accepted=False, headset_accepted=False, multiplayer_accepted=False)
