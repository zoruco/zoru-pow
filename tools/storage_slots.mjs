#!/usr/bin/env node
import fs from 'node:fs';
import createHash from 'keccak';

// Solidity mapping slots: keccak256(abi.encode(key, declarationSlot)).
const values = JSON.parse(fs.readFileSync(0, 'utf8'));
if (!Array.isArray(values) || values.length > 100000) throw new Error('Invalid bounded slot request');
console.log(JSON.stringify(values.map(({ key, slot }) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(key) || !Number.isSafeInteger(slot) || slot < 0 || slot > 255) {
    throw new Error('Canonical mapping key and declaration slot required');
  }
  return '0x' + createHash('keccak256').update(Buffer.from(key.slice(2) + slot.toString(16).padStart(64, '0'), 'hex')).digest('hex');
})));
