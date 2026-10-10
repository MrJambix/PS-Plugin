#!/usr/bin/env node
'use strict';

// jcheck self-test.
//
// A checker that has never been seen to fail is not evidence of anything. The
// fixture under fixture/ contains one deliberate instance of each class of
// problem jcheck claims to find; this runs against it and asserts that every
// one of them is reported, and that the exit code is non-zero.
//
// Run it after changing check.js. If a pass stops firing, this says so here
// rather than by quietly reporting a clean bill of health on real code.

const { execFileSync } = require('child_process');
const path = require('path');

const EXPECTED = [
  {
    what: 'syntax error',
    pattern: /bad_syntax\.lua[\s\S]*?ERROR syntax:/,
  },
  {
    what: 'rt.* read at factory scope before it is built',
    pattern: /ERROR rt\.cache is read at factory scope but is built later/,
  },
  {
    what: 'rt.* that main.lua never assigns',
    pattern: /ERROR rt\.ghost is read but main\.lua never assigns it/,
  },
  {
    what: 'core.* path that is not in the stubs',
    pattern: /WARN\s+core path not in \.api stubs: core\.spell_book\.get_spell_nmae/,
  },
  {
    what: 'undefined global',
    pattern: /WARN\s+undefined global: mathh/,
  },
  {
    what: 'misspelled method name',
    pattern: /WARN\s+method name appears nowhere else: get_helath/,
  },
];

// Things that must NOT be reported: the fixture calls these correctly, and a
// pass that flags them is producing noise rather than findings.
const FORBIDDEN = [
  { what: 'a real method call', pattern: /method name appears nowhere else: get_health\b/ },
  { what: 'a real method call', pattern: /method name appears nowhere else: is_moving\b/ },
  { what: 'a real core path', pattern: /core path not in \.api stubs: core\.spell_book\.get_spell_name\b/ },
];

function run() {
  const fixture = path.join(__dirname, 'fixture');
  let output;
  let exitCode = 0;

  try {
    output = execFileSync(process.execPath, [path.join(__dirname, 'check.js'), fixture], {
      encoding: 'utf8',
    });
  } catch (err) {
    // A non-zero exit is the expected outcome here: the fixture has errors.
    output = `${err.stdout || ''}${err.stderr || ''}`;
    exitCode = err.status;
  }

  let failures = 0;

  if (exitCode === 0) {
    console.log('FAIL  exit code was 0; the fixture contains errors and should have failed');
    failures++;
  } else {
    console.log(`ok    exit code ${exitCode}`);
  }

  for (const { what, pattern } of EXPECTED) {
    if (pattern.test(output)) {
      console.log(`ok    detected: ${what}`);
    } else {
      console.log(`FAIL  NOT detected: ${what}`);
      failures++;
    }
  }

  for (const { what, pattern } of FORBIDDEN) {
    if (pattern.test(output)) {
      console.log(`FAIL  false positive on ${what}`);
      failures++;
    } else {
      console.log(`ok    no false positive on ${what}`);
    }
  }

  console.log(`\n${failures === 0 ? 'self-test passed' : `self-test FAILED (${failures})`}`);
  if (failures > 0) {
    console.log('\n--- checker output ---');
    console.log(output);
  }
  process.exit(failures === 0 ? 0 : 1);
}

run();
