#!/usr/bin/env python3
"""Emit GitHub Actions annotations for flutter test --machine failures."""
import json
import sys


def esc(s):
    return s.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def relpath(p):
    if not p:
        return None
    parts = p.rsplit('/app/', 1)
    if len(parts) == 2:
        return parts[1]
    return p.split('/')[-1]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/machine.log'
    suites = {}
    tests = {}
    errors = {}
    prints = {}
    n_json = 0
    for raw in open(path, encoding='utf-8', errors='replace'):
        line = raw.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if not isinstance(ev, dict):
            continue
        n_json += 1
        t = ev.get('type')
        if t == 'suite':
            s = ev.get('suite') or {}
            suites[s.get('id')] = s.get('path') or ''
        elif t == 'testStart':
            test = ev.get('test') or {}
            url = test.get('url') or suites.get(test.get('suiteID'), '')
            fname = relpath(url) or 'unknown'
            tests[test.get('id')] = (test.get('name') or '?', fname)
        elif t == 'error':
            tid = ev.get('testID')
            errors.setdefault(tid, []).append(ev.get('error') or '')
        elif t == 'print':
            tid = ev.get('testID')
            prints.setdefault(tid, []).append(ev.get('message') or '')
        elif t == 'testDone':
            if ev.get('result') in ('failure', 'error') and not ev.get('hidden'):
                tid = ev.get('testID')
                name, fname = tests.get(tid, ('?', '?'))
                pieces = []
                for m in errors.get(tid, []):
                    if m and 'See exception logs above' not in m:
                        pieces.append(m)
                for m in prints.get(tid, []):
                    pieces.append(m)
                text = '\n'.join(x for x in pieces if x).strip()
                if not text:
                    text = 'Test failed. See exception logs above.'
                print('::error file=%s,line=1,col=1::%s'
                      % (fname, esc(name + ' :: ' + text[:2500])))
    print('::error::DEBUG-STATS json=%d' % n_json)


if __name__ == '__main__':
    main()
