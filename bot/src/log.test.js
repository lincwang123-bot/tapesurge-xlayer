import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initLog, redact } from './log.js';

test('redact removes secrets and URL paths', () => {
  const key = '0x' + 'ab'.repeat(32);
  initLog('/tmp/tapesurge-bot-test.log', [key, key.slice(2), 'https://rpc.example/SECRETKEY']);
  assert.equal(redact(`key ${key}`), 'key <redacted>');
  assert.equal(redact(`bare ${key.slice(2)}`), 'bare <redacted>');
  assert.equal(redact('rpc https://rpc.example/SECRETKEY failed'), 'rpc <redacted> failed');
  assert.equal(redact('other https://node.example/v1/abc123?x=1'), 'other https://node.example/…');
  // 交易哈希这类公开数据保留
  const hash = '0x' + '12'.repeat(32);
  assert.equal(redact(hash), hash);
});
