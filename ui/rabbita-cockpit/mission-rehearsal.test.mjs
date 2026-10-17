import test from 'node:test'
import assert from 'node:assert/strict'
import { createRehearsal, transitionRehearsal as step } from './mission-rehearsal.js'
import { excavationDraft } from './design-workbench.js'

test('R578 complete bounded tabletop loop and ended sequence require explicit reset', () => {
  const initial = createRehearsal(excavationDraft())
  let s = step(initial, 'start')
  assert.throws(() => step(s, 'start'))
  for (let i = 0; i < s.steps.length; i++) s = step(s, 'next')
  assert.equal(s.state, 'completed'); assert.equal(s.cursor, 4)
  for (const action of ['next', 'start', 'hold', 'gap', 'hazard']) assert.throws(() => step(s, action))
  s = step(s, 'reset'); assert.equal(s.cursor, 0); assert.equal(s.state, 'ready')
  assert.equal(s.physical_execution_allowed, false); assert.equal(initial.cursor, 0)
})

test('R578 hazard and telemetry recovery remain independent interlocks', () => {
  let s = step(createRehearsal(excavationDraft()), 'start')
  s = step(s, 'gap'); s = step(s, 'hazard')
  assert.equal(s.unknown, true); assert.equal(s.cursor, 0)
  for (const action of ['next', 'start', 'done', 'not-started']) assert.throws(() => step(s, action))
  s = step(s, 'restore'); assert.equal(s.state, 'held'); assert.equal(s.unknown, true)
  assert.throws(() => step(s, 'start'))
  s = step(s, 'done'); assert.equal(s.cursor, 1); assert.equal(s.state, 'held')
  assert.throws(() => step(s, 'done')); assert.throws(() => step(s, 'start'))
  s = step(s, 'clear'); assert.equal(s.state, 'held')
  s = step(s, 'start'); s = step(s, 'next'); assert.equal(s.cursor, 2)
})

test('R578 simulated never-started evidence preserves step and does not resume', () => {
  let s = step(createRehearsal(excavationDraft()), 'start')
  s = step(s, 'gap'); s = step(s, 'gap'); s = step(s, 'restore'); s = step(s, 'not-started')
  assert.equal(s.cursor, 0); assert.equal(s.state, 'held'); assert.equal(s.unknown, false)
  assert.throws(() => step(s, 'next')); assert.throws(() => step(s, 'not-started'))
  s = step(s, 'start'); s = step(s, 'next'); assert.equal(s.cursor, 1)
})

test('R578 stop resume and speed limits enforce manual bounded practice', () => {
  let s = createRehearsal(excavationDraft())
  for (const speed of [NaN, Infinity, -1, 0, 0.11]) assert.throws(() => step(s, 'speed', speed))
  s = step(s, 'speed', 0.1); s = step(s, 'start')
  assert.throws(() => step(s, 'speed', 0.05))
  s = step(s, 'hold'); s = step(s, 'hold'); assert.equal(s.cursor, 0)
  s = step(s, 'speed', 0.05); s = step(s, 'start'); s = step(s, 'next')
  assert.equal(s.speed, 0.05); assert.equal(s.cursor, 1)
})

test('R578 rejecting unsupported designs and preserving source loop', () => {
  const d = excavationDraft(), s = createRehearsal(d)
  d.task_loop[0] = 'changed'; assert.notEqual(s.steps[0], d.task_loop[0])
  for (const bad of [null, {}, { ...d, mission: { ...d.mission, authority: 'physical' } }, { ...d, task_loop: ['one'] }, { ...d, constraints: { commanded_speed_mps: { min: 0.1, max: Infinity } } }]) assert.throws(() => createRehearsal(bad))
  assert.throws(() => step(s, 'dispatch'))
})
