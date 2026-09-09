#!/usr/bin/env python3
"""Emit GitHub Actions annotations for flutter test --machine output."""
import json
import os
import sys
import traceback


def esc(s):
    return s.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main():
    print('::error::PY-OK')
    sys.stdout.flush()
    path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/machine.log'
    tests = {}
    errors = {}
    n_start = 0
    n_done = 0
    n_fail = 0
    n_err = 0
    n_json = 0
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                    n_json += 1
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
                        print('::error file=test/%s,line=1,col=1::%s'
                              % (fname, esc(name + ' :: ' + text[:1200])))
                        sys.stdout.flush()
    except Exception:
        print('::error::PY-EXC ' + esc(traceback.format_exc()[:1500]))
    finally:
        print('::error::DEBUG-STATS json=%d start=%d done=%d fail=%d err_events=%d'
              % (n_json, n_start, n_done, n_fail, n_err))
        sys.stdout.flush()


if __name__ == '__main__':
    main()
