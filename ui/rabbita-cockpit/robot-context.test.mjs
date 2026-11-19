import test from 'node:test'
import assert from 'node:assert/strict'
import { resolveRobotContext, experimentsForRobot, assertRobotReplay } from './robot-context.js'

test('explicit robot selection survives stale experiment links; shared links select their registered robot', () => {
  const experimentRobotIds = { recorded: 'g1-simulation' }
  assert.equal(resolveRobotContext({ search: '?robot=workspace&experiment=recorded', stored: 'g1-simulation', experimentRobotIds }), 'workspace')
  assert.equal(resolveRobotContext({ search: '?experiment=recorded', stored: 'workspace', experimentRobotIds }), 'g1-simulation')
  assert.equal(resolveRobotContext({ stored: 'g1-simulation' }), 'g1-simulation')
  assert.equal(resolveRobotContext({ search: '?robot=unknown&experiment=unregistered', stored: 'unknown' }), 'workspace')
})

test('experiment ownership is derived from source manifests and missing ownership is excluded', () => {
  const registry = { experiments: ['g1', 'e1', 'missing'].map(experiment_id => ({ experiment_id })), experiment_robot_ids: { g1: 'g1-simulation', e1: 'noetix-e1-lab-01' } }
  assert.deepEqual(experimentsForRobot(registry, 'g1-simulation').map(e => e.experiment_id), ['g1'])
  assert.deepEqual(experimentsForRobot(registry, 'noetix-e1-lab-01').map(e => e.experiment_id), ['e1'])
  assert.deepEqual(experimentsForRobot({ experiments: registry.experiments }, 'g1-simulation'), [])
})

test('model and replay reject a foreign or unidentified robot instead of substituting geometry', () => {
  const g1 = { source: { model_ref: 'mujoco-menagerie:revision:unitree_g1/scene_mjx.xml' } }
  assert.equal(assertRobotReplay(g1, 'g1-simulation'), g1)
  assert.throws(() => assertRobotReplay(g1, 'workspace'), /different robot/)
  assert.throws(() => assertRobotReplay({ source: { model_ref: 'unitree_h1/scene.xml' } }, 'g1-simulation'), /different robot/)
  assert.throws(() => assertRobotReplay({}, 'g1-simulation'), /different robot/)
})
