import { test, expect } from 'claude-code/testing'

type Copy = { text: string; surface?: string }

const SID = '00000000-0000-4000-8000-000000000001'

/** Engine stand-ins: command registration, and a clipboard that takes or refuses the copy. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function setup(on: any, clipboard: 'takes' | 'refuses') {
  const seen = { copies: [] as Copy[], registered: [] as string[] }
  on('command.register', async ($: unknown, e: { name: string }) => {
    seen.registered.push(e.name)
    return { value: undefined }
  })
  on('session.id', async () => ({ value: SID }))
  on('ui.copy', async ($: unknown, e: Copy) => {
    seen.copies.push(e)
    return { value: clipboard === 'takes' ? { isCopied: true } : { isCopied: false, reason: 'no-clipboard' } }
  })
  on('session.start', async ($: unknown, e: unknown) => e)
  on('command.run', async () => ({ text: 'unhandled' }))
  return seen
}

const run = { command: 'copy-session-id', args: '' } as never

test('/copy-session-id puts the session id on the clipboard', async ($, on) => {
  const seen = setup(on, 'takes')
  await $.session.start({ cwd: '/tmp', surface: 'terminal' } as never)
  expect(seen.registered).toContain('copy-session-id')

  const r = await $.command.run(run)
  expect(seen.copies).toEqual([{ text: SID }])
  expect((r as { text: string }).text).toBe('copied session id ' + SID)
})

test('a refused copy still shows the id, and says why', async ($, on) => {
  const seen = setup(on, 'refuses')
  const r = await $.command.run(run)
  expect(seen.copies).toEqual([{ text: SID }])
  expect((r as { text: string }).text).toBe('session id ' + SID + ' (not copied: no-clipboard)')
})
