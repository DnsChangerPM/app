#!/usr/bin/env python3
"""Dump flutter test --machine log lines as annotations for inspection."""
import sys


def esc(s):
    return s.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/machine.log'
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    print('::error::TOTAL-LINES %d' % len(lines))
    for i, line in enumerate(lines[:40]):
        print('::error::HEAD %d: %s' % (i, esc(line[:400])))
    for i, line in enumerate(lines[-20:], start=max(0, len(lines) - 20)):
        print('::error::TAIL %d: %s' % (i, esc(line[:400])))


if __name__ == '__main__':
    main()
