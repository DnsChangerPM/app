#!/usr/bin/env python3
"""Emit GitHub Actions annotations for flutter test --machine failures."""
import sys


def esc(s):
    return s.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def relpath(p):
    if not p:
        return None
    # /home/runner/work/<repo>/<repo>/test/foo_test.dart -> test/foo_test.dart
    parts = p.rsplit('/app/', 1)
    if len(parts) == 2:
        return parts[1]
    return p.split('/')[-1]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/machine.log'
    suites = {}
    tests = {}
    errors = {}
    n_start = n_done = n_fail = n_err = n_json = 0
    for raw in open(path, encoding='utf-8', errors='replace'):
        line = raw.strip()
        if not line:
            continue
        try:
            ev = __import__('json').loads(line)
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
            n_start += 1
            test = ev.get('test') or {}
            url = test.get('url') or suites.get(test.get('suiteID'), '')
            fname = relpath(url) or 'unknown'
            tests[test.get('id')] = (test.get('name') or '?', fname)
        elif t == 'error':
            n_err += 1
            tid = ev.get('testID')
            errors.setdefault(tid, []).append(ev.get('error') or '')
        elif t == 'testDone':
            n_done += 1
            if ev.get('result') in ('failure', 'error') and not ev.get('hidden'):
                n_fail += 1
                tid = ev.get('testID')
                name, fname = tests.get(tid, ('?', '?'))
                msg = errors.get(tid) or ['(no message)']
                text = ' | '.join(x for x in msg if x).strip()
                print('::error file=%s,line=1,col=1::%s'
                      % (fname, esc(name + ' :: ' + text[:1200])))
    print('::error::DEBUG-STATS json=%d start=%d done=%d fail=%d err_events=%d'
          % (n_json, n_start, n_done, n_fail, n_err))


if __name__ == '__main__':
    main()
