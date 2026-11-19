import test from 'node:test'
import assert from 'node:assert/strict'
import { createCopyTranslator } from './public/translate-copy.js'
import { workspaceMessages } from './public/workspace-messages.js'
import { learningMessages, learningTemplates } from './public/learning-messages.js'
import { statusMessages, statusTemplates } from './public/status-messages.js'

const translate = createCopyTranslator({ ...workspaceMessages, ...learningMessages, ...statusMessages }, [...learningTemplates, ...statusTemplates])
test('Chinese learning copy also renders in English, including accessible labels', () => {
  assert.equal(translate('搜索实验…', 'en-US'), 'Search experiments…')
  assert.equal(translate('切换浅色模式', 'en-US'), 'Switch to light mode')
  assert.equal(translate('参考动作 · 前馈初始化', 'en-US'), 'Reference motion · Feedforward initialization')
  assert.equal(translate('查看 reference-feedforward-initialization 的结果', 'en-US'), 'View results for reference-feedforward-initialization')
})
test('runtime copy renders in Chinese without losing counts or routes', () => {
  assert.equal(translate('Runtime validation blocked; failures 13', 'zh-Hans'), '连接验证受阻，13 项失败')
  assert.equal(translate('Learning experiment warm', 'zh-Hans'), '学习实验 warm')
  assert.equal(translate('next: /api/moonclaw/context', 'zh-Hans'), '下一步：/api/moonclaw/context')
})
test('both template directions preserve parameter order and whitespace', () => {
  const zh = ' 服务暂不可用 · 显示 2026-10-28 导出的 48 个实验 '
  const en = ' Service unavailable · Showing 48 experiments exported on 2026-10-28 '
  assert.equal(translate(zh, 'en-US'), en)
  assert.equal(translate(en, 'zh-Hans'), zh)
})
test('playback updates translate at every frame without altering time', () => {
  assert.equal(translate('已暂停 · 4.250 s', 'en-US'), 'Paused at 4.250 s.')
  assert.equal(translate('Physics ended at 2.500 s · Holding final pose', 'zh-Hans'), '仿真结束于 2.500 s · 保留末帧')
})
test('unknown identifiers, paths and units are never guessed', () => {
  for (const text of ['reference-feedforward-initialization', 'constructor', 'toString', '/api/moonclaw/context', '0.032 rad', '10.000 s / 30.000 s', 'inspect robot status']) {
    for (const locale of ['en-US', 'zh-Hans']) assert.equal(translate(text, locale), text)
  }
  assert.equal(translate('MOONROBO / MOTION LEARNING', 'en-US'), 'MOONROBO / MOTION LEARNING')
})
test('numeric templates do not swallow adjacent copy or decorative arrows', () => {
  assert.equal(translate('3 个候选 · 0 个记录达标', 'en-US'), '3 candidates · 0 records qualified')
  assert.equal(translate('40 / 40 条动作', 'en-US'), '40 / 40 motions')
  assert.equal(translate('SuperMimic 原站 · 2026-10-28 查看 ↗', 'en-US'), 'SuperMimic website · Viewed 2026-10-28 ↗')
  assert.equal(translate('40 / 40 终止失败，保留逐动作误差。', 'en-US'), '40 / 40 terminated; per-motion errors retained.')
})
test('translated copy is stable under repeated DOM observations', () => {
  for (const text of ['终止失败', '全部实验', 'Playback help', 'Switch to light mode', 'Local service connected · 48 experiments · 2 with 3D replay']) {
    for (const locale of ['en-US', 'zh-Hans']) {
      const result = translate(text, locale)
      assert.equal(translate(result, locale), result)
    }
  }
})
test('navigation Trials remains distinct from recorded trajectories', () => {
  assert.equal(translate('Trials', 'zh-Hans'), '试验')
  assert.equal(translate('Trial records', 'zh-Hans'), '轨迹')
})
