import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isValidDeviceId, parseDeviceLimit, escHtml, fmtDateSafe } from '../src/index.js';

test('device_id validation', () => {
  assert.equal(isValidDeviceId('abc-12_Z'), true);
  assert.equal(isValidDeviceId(''), false);
  assert.equal(isValidDeviceId("a'><img"), false);
  assert.equal(isValidDeviceId('x'.repeat(65)), false);
});

test('device_limit 0 is unlimited', () => {
  assert.equal(parseDeviceLimit(0), 0);
  assert.equal(parseDeviceLimit('0'), 0);
  assert.equal(parseDeviceLimit(undefined), 1);
  assert.equal(parseDeviceLimit('nope'), 1);
});

test('escHtml escapes quotes and tags', () => {
  assert.equal(escHtml(`a'><img src=x onerror=alert(1)>`), 'a&#39;&gt;&lt;img src=x onerror=alert(1)&gt;');
});

test('fmtDateSafe does not throw', () => {
  assert.equal(fmtDateSafe('not-a-date'), '—');
  assert.equal(fmtDateSafe(0), '—');
  assert.match(fmtDateSafe('2024-01-02T03:04:05Z'), /2024-01-02/);
});
