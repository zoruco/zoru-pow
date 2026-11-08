#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { assertStorageUpgradeSafe, validate, solcInputOutputDecoder } from '@openzeppelin/upgrades-core';
import { unfoldStorageLayout } from '@openzeppelin/upgrades-core/dist/validate/query.js';

const require = createRequire(import.meta.url);
const root = path.resolve(import.meta.dirname, '..');
const baseline = process.argv[3] || '75a63bd0c0a0fe836c732e54e44d0cf14d33f628';
assert(/^[0-9a-f]{40}$/.test(baseline), 'Supply an exact deployed source commit');
const contracts = ['ZoruLedger', 'ZoruDrandBeacon'];
const names = contracts.map(name => `src/${name}.sol:${name}`);
const builds = fs.readdirSync(path.join(root, 'contracts/out/build-info')).filter(f => f.endsWith('.json'))
    .map(f => JSON.parse(fs.readFileSync(path.join(root, 'contracts/out/build-info', f))));
const build = builds.find(b => names.every(name => {
    const [source, contract] = name.split(':');
    return b.output?.contracts?.[source]?.[contract]?.storageLayout
        && b.input.sources[source]?.content === fs.readFileSync(path.join(root, "contracts", source), "utf8");
}));
assert(build, 'Build all contracts with --build-info --extra-output storageLayout');
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
for (let i = 0; i < contracts.length; ++i) {
    const previous = JSON.parse(execFileSync('git', ['show', `${baseline}:release/layout/${contracts[i]}.json`], { cwd: root, encoding: 'utf8' }));
    assertStorageUpgradeSafe(previous, layouts[i]);
}
const ledger = layouts[0];
for (const [label, slot] of Object.entries({ legacyEpochs: '12', legacyProofs: '13', compactProofs: '16', compactEpochs: '21' }))
    assert.equal(ledger.storage.find(v => v.label === label).slot, slot);
const raw = build.output.contracts['src/ZoruLedger.sol'].ZoruLedger.storageLayout;
for (const [label, size] of Object.entries({ compactProofs: 32, compactEpochs: 96 })) {
    const field = raw.storage.find(v => v.label === label);
    assert.equal(Number(raw.types[raw.types[field.type].value].numberOfBytes), size);
}
const result = { status: 'PASS', validator: '@openzeppelin/upgrades-core', version: require('@openzeppelin/upgrades-core/package.json').version,
    compiler: build.solcLongVersion, baselineCommit: baseline, unsafeOverrides: [],
    comparisons: contracts.map(name => `deployed ${name} -> candidate ${name}`) };
if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result, null, 2));
