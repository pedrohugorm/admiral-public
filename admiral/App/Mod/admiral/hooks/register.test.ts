import { test, expect, mock } from 'claude-code/testing'
import { MODEL, SYSTEM } from './register'

// Obviously fake test data — never a real patient. The model is mocked, so the scrubber needs
// no date shape here; the birth year alone stands in for the identifier being redacted.
const REPLY = 'Request filed for John Testerston, born 1970.'
const SCRUBBED = 'Request filed for [REDACTED], born [REDACTED].'
const FLAG = '/tmp/admiral-test/sessions/T/redact-replies'
const DIR = '/tmp/admiral-test/sessions/T/redacted-output'
const FILE = '/tmp/admiral-test/sessions/T/structured-output.json'

type Model = { isAnswered: boolean; text?: string; reason?: string }
type Slot = Record<string, unknown>

const slots = (output: Slot) => JSON.stringify({ slots: { output } })
const fulfilled = (round: number, result: unknown): Slot =>
  ({ status: 'fulfilled', round, result, completedAt: 781000000, schema: {}, delivery: 'tool_use', attempts: 0, blocks: 0 })

/** Engine stand-ins: env, a clock, the files, a model, and a recorder for writes. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function setup(on: any, opts: { flag?: boolean; slot?: Slot | null; existing?: string[]; model?: Model }) {
  const seen = { modelCalls: [] as { model: string; prompt: string }[], writes: [] as { path: string; text: string }[] }
  const model = opts.model ?? { isAnswered: true, text: SCRUBBED }
  mock.env(on, { ADMIRAL_REDACT_FLAG: FLAG, ADMIRAL_REDACTED_DIR: DIR, ADMIRAL_OUTPUT_FILE: FILE })
  const clock = mock.clock(on, { now: 1000 })
  on('fs.exists', async ($: unknown, e: { path: string }) => ({
    value: (e.path === FLAG && opts.flag !== false) || (e.path === FILE && opts.slot != null)
      || (opts.existing ?? []).includes(e.path),
  }))
  on('fs.read', async ($: unknown, e: { path: string }) => {
    if (e.path !== FILE || opts.slot == null) throw new Error('missing')
    return { value: slots(opts.slot) }
  })
  on('model.complete', async ($: unknown, e: { model: string; prompt: string }) => {
    seen.modelCalls.push(e)
    return { value: { usage: {}, ...model } }
  })
  on('fs.write', async ($: unknown, e: { path: string; text: string }) => {
    seen.writes.push(e)
    return { value: undefined }
  })
  on('turn.complete', async ($: unknown, e: { answer: string }) => ({ text: e.answer }))
  return { clock, seen }
}

const turn = (answer: string, extra: Record<string, unknown> = {}) => ({
  answer, durationMs: 5, isAborted: false, turnId: 'turn-1', reason: 'answer', ...extra,
})

test("a fulfilled round's result is redacted by Sonnet and written once per round", async ($, on) => {
  const { clock, seen } = setup(on, { slot: fulfilled(2, { slack_reply: REPLY, lines: 4 }) })
  const result = await $.turn.complete(turn('some hook chatter') as never)
  expect(result.text).toBe('some hook chatter') // the turn itself is untouched
  await clock.advance(5)
  expect(seen.modelCalls.length).toBe(1)
  expect(seen.modelCalls[0].model).toBe(MODEL)
  expect(seen.modelCalls[0].prompt).toContain(REPLY)
  expect(seen.writes.length).toBe(1)
  expect(seen.writes[0].path).toBe(DIR + '/output-2.json')
  const written = JSON.parse(seen.writes[0].text)
  expect(written.round).toBe(2)
  expect(written.status).toBe('fulfilled')
  expect(written.result).toEqual({ slack_reply: SCRUBBED, lines: 4 })
  expect(written.completedAt).toBe(781000000)
  expect(written.failed).toBe(false)
})

test('the reply text is never what gets redacted', async ($, on) => {
  const { clock, seen } = setup(on, { slot: fulfilled(1, { slack_reply: 'the answer' }) })
  await $.turn.complete(turn(REPLY) as never)
  await clock.advance(5)
  expect(seen.modelCalls.every((c) => !c.prompt.includes(REPLY))).toBe(true)
})

test('the prompt wrapper Sonnet echoes back is stripped before the copy is written', async ($, on) => {
  const { clock, seen } = setup(on, {
    slot: fulfilled(1, { slack_reply: REPLY }),
    model: { isAnswered: true, text: '<text>\n' + SCRUBBED + '\n</text>' },
  })
  await $.turn.complete(turn('x') as never)
  await clock.advance(5)
  expect(JSON.parse(seen.writes[0].text).result.slack_reply).toBe(SCRUBBED)
})

test('a model failure writes a failed copy with no result, never the raw one', async ($, on) => {
  const { clock, seen } = setup(on, {
    slot: fulfilled(1, { slack_reply: REPLY }), model: { isAnswered: false, reason: 'error' },
  })
  await $.turn.complete(turn('x') as never)
  await clock.advance(5)
  const written = JSON.parse(seen.writes[0].text)
  expect(written.failed).toBe(true)
  expect(written.result).toBe(null)
  expect(seen.writes[0].text).not.toContain('Testerston')
})

test('a failed round is written as failed without calling the model', async ($, on) => {
  const { clock, seen } = setup(on, { slot: { status: 'failed', round: 3, violations: ['no call'] } })
  await $.turn.complete(turn('x') as never)
  await clock.advance(5)
  expect(seen.modelCalls.length).toBe(0)
  const written = JSON.parse(seen.writes[0].text)
  expect(written).toMatchObject({ round: 3, status: 'failed', result: null, violations: ['no call'], failed: false })
})

test('a round already copied is not redacted again', async ($, on) => {
  const { clock, seen } = setup(on, {
    slot: fulfilled(4, { slack_reply: REPLY }), existing: [DIR + '/output-4.json'],
  })
  await $.turn.complete(turn('x') as never)
  await clock.advance(5)
  expect(seen.writes.length).toBe(0)
})

test('an armed slot writes nothing', async ($, on) => {
  const { clock, seen } = setup(on, { slot: { status: 'armed', round: 5 } })
  await $.turn.complete(turn('x') as never)
  await clock.advance(5)
  expect(seen.writes.length).toBe(0)
})

test('with the setting off nothing is sent to the model or written', async ($, on) => {
  const { clock, seen } = setup(on, { flag: false, slot: fulfilled(1, { slack_reply: REPLY }) })
  await $.turn.complete(turn('x') as never)
  await clock.advance(5)
  expect(seen.modelCalls.length).toBe(0)
  expect(seen.writes.length).toBe(0)
})

test('subagent turns are skipped', async ($, on) => {
  const { clock, seen } = setup(on, { slot: fulfilled(1, { slack_reply: REPLY }) })
  await $.turn.complete(turn('x', { agentId: 'sub-1' }) as never)
  await clock.advance(5)
  expect(seen.modelCalls.length).toBe(0)
})

test('the redaction prompt keeps Prescription and Case IDs', async () => {
  // Internal system keys, not identifiers of a person: investigations report them.
  expect(SYSTEM).toContain('Do not redact Prescription IDs or Case IDs')
})
