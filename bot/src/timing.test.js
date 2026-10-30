import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkInterval } from './timing.js';

test('second testnet deployment honors its 48x time scale', () => {
  const dep = { fast: true, timeDivisor: 48 };
  assert.equal(checkInterval(86400, dep, 97), 1800);
  assert.equal(checkInterval(3600, dep, 97), 75);
  assert.equal(checkInterval(600, dep, 97), 15);
});

test('X Layer testnet records only timeDivisor (no fast flag) and is still scaled', () => {
  assert.equal(checkInterval(43_200, { timeDivisor: 48 }, 1952), 900);
  assert.equal(checkInterval(86400, { timeDivisor: 720 }, 1952), 120);
});

test('legacy fast deployment uses 720x; unscaled and mainnet schedules stay normal', () => {
  assert.equal(checkInterval(86400, { fast: true }, 97), 120);
  assert.equal(checkInterval(86400, {}, 97), 86400);
  assert.equal(checkInterval(86400, { timeDivisor: 1 }, 196), 86400);
  assert.equal(checkInterval(86400, { fast: true, timeDivisor: 48 }, 56), 86400);
  assert.equal(checkInterval(86400, { timeDivisor: 48 }, 196), 86400);
});

test('invalid recorded timing must not silently produce a bad schedule', () => {
  for (const timeDivisor of [0, -1, 0.5, 'oops']) {
    assert.throws(() => checkInterval(3600, { fast: true, timeDivisor }, 97), /timeDivisor/);
  }
});
