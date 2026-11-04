#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertStorageUpgradeSafe, validate, solcInputOutputDecoder } from '@openzeppelin/upgrades-core';
import { unfoldStorageLayout } from '@openzeppelin/upgrades-core/dist/validate/query.js';

// Use compiler AST annotations and full inherited layouts. No unsafe overrides.
const require = createRequire(import.meta.url);
const root = path.resolve(import.meta.dirname, '..');
const files = fs.readdirSync(path.join(root, 'contracts/out/build-info')).filter(x => x.endsWith('.json'));
const builds = files.map(f => JSON.parse(fs.readFileSync(path.join(root, 'contracts/out/build-info', f))));
const names = ['test/fixtures/ZoruLedgerV1.sol:ZoruLedgerV1', 'src/ZoruLedgerMigration.sol:ZoruLedgerMigration', 'src/ZoruLedger.sol:ZoruLedger',
  'test/fixtures/ZoruDrandBeaconOriginal.sol:ZoruDrandBeaconOriginal', 'src/ZoruDrandBeaconMigration.sol:ZoruDrandBeaconMigration', 'src/ZoruDrandBeacon.sol:ZoruDrandBeacon'];
const build = builds.find(b => names.every(name => {
  const [source, contract] = name.split(':');
  return b.output?.contracts?.[source]?.[contract]?.storageLayout;
}));
assert(build, 'Rebuild all contracts with forge build --force --build-info --extra-output storageLayout');
// Foundry can emit the same imported source under a relative alias as well as
// its canonical absolute path. Supply the identical compiler-input content for
// those aliases, without modifying the compiler output or storage layouts.
for (const source of Object.keys(build.output.sources)) {
  if (build.input.sources[source]) continue;
  const canonical = fs.realpathSync(path.resolve(root, 'contracts', source));
  const original = Object.entries(build.input.sources).find(([name]) =>
    fs.realpathSync(path.resolve(root, 'contracts', name)) === canonical);
  assert(original, `Compiler input missing for ${source}`);
  build.input.sources[source] = original[1];
}
const validation = validate(build.output, solcInputOutputDecoder(build.input, build.output), build.solcVersion, build.input);
const layouts = names.map(name => unfoldStorageLayout(validation, name));
const released = JSON.parse(fs.readFileSync(path.join(root, 'contracts/test/fixtures/ZoruLedger.layout.json')));
// Compare the reconstructed V1 against the original release layout, too.
assertStorageUpgradeSafe(released, layouts[0]);
assertStorageUpgradeSafe(layouts[0], layouts[1]);
assertStorageUpgradeSafe(layouts[1], layouts[2]);
const releasedBeacon = JSON.parse(fs.readFileSync(path.join(root, 'contracts/test/fixtures/ZoruDrandBeacon.layout.json')));
assertStorageUpgradeSafe(releasedBeacon, layouts[3]);
assertStorageUpgradeSafe(layouts[3], layouts[4]);
assertStorageUpgradeSafe(layouts[4], layouts[5]);
assert.equal(layouts[0].storage.find(v => v.label === 'proofs').slot, '13');
for (const [index, layout] of layouts.slice(1, 3).entries()) {
  assert.equal(layout.storage.find(v => v.label === 'legacyProofs').slot, '13');
  assert.equal(layout.storage.find(v => v.label === 'compactProofs').slot, '16');
  assert.equal(layout.storage.find(v => v.label === 'legacyEpochs').slot, '12');
  assert.equal(layout.storage.find(v => v.label === 'compactEpochs').slot, '21');
  const [source, contract] = names[index + 1].split(':');
  const raw = build.output.contracts[source][contract].storageLayout;
  const proofMapping = raw.storage.find(v => v.label === 'compactProofs');
  const epochMapping = raw.storage.find(v => v.label === 'compactEpochs');
  assert.equal(Number(raw.types[raw.types[proofMapping.type].value].numberOfBytes), 32);
  assert.equal(Number(raw.types[raw.types[epochMapping.type].value].numberOfBytes), 96);
}
for (const layout of layouts.slice(4)) {
  assert.equal(layout.storage.find(v => v.label === 'cachedSeed').slot, '0');
  assert.equal(layout.storage.find(v => v.label === 'cachedConfig').slot, '3');
  assert.equal(layout.storage.find(v => v.label === 'activeSeed').slot, '4');
  assert.equal(layout.storage.find(v => v.label === 'activeTrust').slot, '6');
}
const result = { status: 'PASS', validator: '@openzeppelin/upgrades-core', version: require('@openzeppelin/upgrades-core/package.json').version,
  compiler: build.solcLongVersion, unsafeOverrides: [], comparisons: ['released Ledger -> original fixture', 'original Ledger -> migration', 'migration Ledger -> final',
    'released Beacon -> original fixture', 'original Beacon -> migration', 'migration Beacon -> final'],
  historicalProofMappingSlot: '13', compactProofMappingSlot: '16', contracts: names };
if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result, null, 2));
