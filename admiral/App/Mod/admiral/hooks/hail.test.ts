import { test, expect } from 'claude-code/testing'
import { HAIL_USAGE, parseHail } from './register'

type Call = { server: string; tool: string; args: Record<string, unknown> }

/** Engine stand-ins: command registration, and a bridge that answers `hail` as told. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function setup(on: any, bridge: { isError: boolean; text: string } | 'throws') {
  const seen = { calls: [] as Call[], registered: [] as string[] }
  on('command.register', async ($: unknown, e: { name: string }) => {
    seen.registered.push(e.name)
    return { value: undefined }
  })
  on('mcp.call', async ($: unknown, e: Call) => {
    seen.calls.push(e)
    if (bridge === 'throws') throw new Error('server "bridge" is not connected')
    return { value: { content: [{ type: 'text', text: bridge.text }], isError: bridge.isError } }
  })
  on('session.start', async ($: unknown, e: unknown) => e)
  on('command.run', async () => ({ text: 'unhandled' }))
  return seen
}

const run = (args: string) => ({ command: 'hail', args }) as never

test('/hail sends the message through the bridge, signed as this tab', async ($, on) => {
  const seen = setup(on, { isError: false, text: 'hailed @worker (id abc123)' })
  await $.session.start({ cwd: '/tmp', surface: 'terminal' } as never)
  expect(seen.registered).toContain('hail')

  const r = await $.command.run(run('@worker the build is green, go ahead'))
  expect(seen.calls.length).toBe(1)
  expect(seen.calls[0].server).toBe('bridge')
  expect(seen.calls[0].tool).toBe('hail')
  expect(seen.calls[0].args).toEqual({ to: 'worker', body: 'the build is green, go ahead' })
  expect((r as { text: string }).text).toBe('hailed @worker (id abc123)')
})

test('/hail without a callsign and a message shows the usage and calls nothing', async ($, on) => {
  const seen = setup(on, { isError: false, text: 'x' })
  for (const args of ['', '   ', 'worker', '@worker   ']) {
    const r = await $.command.run(run(args))
    expect((r as { text: string }).text).toBe(HAIL_USAGE)
  }
  expect(seen.calls.length).toBe(0)
})

test('an unknown tab shows the bridge\'s reason', async ($, on) => {
  setup(on, { isError: true, text: 'no station @ghost' })
  const r = await $.command.run(run('ghost hello'))
  expect((r as { text: string }).text).toBe('hail failed: no station @ghost')
})

test('a bridge that is not connected shows why, not a silent nothing', async ($, on) => {
  setup(on, 'throws')
  const r = await $.command.run(run('worker hello'))
  // The call rejects (the engine words the reason); the command says so instead of nothing.
  expect((r as { text: string }).text.startsWith('hail failed: ')).toBe(true)
  expect((r as { text: string }).text.length).toBeGreaterThan('hail failed: '.length)
})

test('parseHail splits the callsign from the message', async () => {
  expect(parseHail('@a  hi  there ')).toEqual({ to: 'a', body: 'hi  there' })
  expect(parseHail('a\thi')).toEqual({ to: 'a', body: 'hi' })
  expect(parseHail('a')).toBe(null)
  expect(parseHail('@ hi')).toBe(null)
})
