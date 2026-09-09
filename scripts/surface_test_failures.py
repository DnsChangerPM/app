#!/usr/bin/env python3
"""Emit GitHub Actions annotations for flutter test --machine output.

Reads a machine-format log from /tmp/machine.log and prints one ::error
workflow command per failed test so failures are visible as annotations.
"""
import json
import os
import sys


def esc(s):
    return s.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/machine.log'
    tests = {}
    errors = {}
    n_start = 0
    n_done = 0
    n_fail = 0
    n_err = 0
    with open(path, encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            t = ev.get('type')
            if t == 'testStart':
                n_start += 1
                test = ev.get('test') or {}
                url = test.get('url') or ''
                fname = url.split('/')[-1] if url else 'unknown'
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
    print('::error::DEBUG-STATS start=%d done=%d fail=%d err_events=%d'
          % (n_start, n_done, n_fail, n_err))


if __name__ == '__main__':
    main()
