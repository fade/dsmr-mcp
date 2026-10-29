// Replays recorded spawns against the routing decision and the hooks module.
//
// A recording is either what register.ts writes under SUBAGENT_ROUTING_CAPTURE
// (`source.kind` "hook") or what routing-probe.sh record-history builds from a
// session transcript (`source.kind` "transcript"): the spawn input, a tape of
// engine answers looked up by call and argument, and an `expected` block added
// by hand. Recordings hold real dispatch prompts, so they stay outside the
// repository; a test file written beside a temporary copy of the mod passes
// them in.

import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'
import type { TapeEntry } from '../hooks/register'
import { decide, ioDirs, type RouteIo } from '../hooks/route'

/** A recorded spawn input; a transcript holds only some of the engine's fields. */
export type RecordedInput = Partial<AgentSpawnInput> &
  Pick<AgentSpawnInput, 'tool_use_id' | 'prompt' | 'subagentType'> & { model?: string | null; cwd?: string }

export type Recording = {
  input: RecordedInput
  tape: TapeEntry[]
  decision?: unknown
  expected: { subagentType: string; model: string | null; action: string; why: string }
  source: { kind: string; capturedAt: string }
}

const LOG_PATH = /\/logs\/subagent-routing\/[^/]+\.jsonl$/

/** Engine answers from one recording; any call it does not hold is a named miss. */
class Tape {
  readonly misses: string[] = []

  constructor(
    private readonly entries: readonly TapeEntry[],
    private readonly label: string,
  ) {}

  answer(op: TapeEntry['op'], arg: string): string | boolean | null {
    const hit = this.entries.find(t => t.op === op && t.arg === arg)
    if (hit === undefined) {
      const miss = `${op}(${arg})`
      this.misses.push(miss)
      throw new Error(`${this.label}: ${miss} is not on the tape`)
    }
    return hit.result
  }

  text(op: TapeEntry['op'], arg: string): string | undefined {
    const v = this.answer(op, arg)
    return typeof v === 'string' ? v : undefined
  }
}

function labelOf(rec: Recording): string {
  return `${rec.input.subagentType} ${rec.input.tool_use_id}`
}

/**
 * The recorded input as the engine hands it to a hook: a null model becomes
 * absent, and the fields a transcript does not hold (none of which the
 * decision reads) take the values of a plain foreground subagent spawn.
 */
function spawnInput(rec: Recording): AgentSpawnInput {
  const { model, ...rest } = rec.input
  return {
    description: '',
    provider: { plugin: 'user', tier: 'user' },
    parentModel: 'unknown',
    background: false,
    fork: false,
    ...rest,
    ...(model === null || model === undefined ? {} : { model }),
  } as AgentSpawnInput
}

/** The spawn log as the hooks module writes it during one test. */
type LogFile = { text: string }

/** Parsed lines of `text` that carry `toolUseId`. */
function logLinesFor(text: string, toolUseId: string): Record<string, unknown>[] {
  return text
    .split('\n')
    .filter(l => l.trim() !== '')
    .map(l => JSON.parse(l) as Record<string, unknown>)
    .filter(l => l.toolUseId === toolUseId)
}

/**
 * Engine stand-ins for one recording: answers come from the tape, the spawn
 * log is kept in `log`, and every spawn passed beneath is pushed to `beneath`.
 * `answer` returns what the engine answers the spawn passed beneath.
 */
function standIns(
  on: On,
  tape: Tape,
  log: LogFile,
  beneath: AgentSpawnInput[],
  answer: (e: AgentSpawnInput, n: number) => { model: string; agentId: string } | { deny: string },
): void {
  on('env.get', (_$, e) =>
    e.name === 'SUBAGENT_ROUTING_CAPTURE' ? { value: undefined } : { value: tape.text('env.get', e.name) },
  )
  on('session.cwd', () => ({ value: tape.text('session.cwd', '') ?? '' }))
  on('session.id', () => ({ value: tape.text('session.id', '') ?? '' }))
  on('fs.read', (_$, e) => {
    if (LOG_PATH.test(e.path)) {
      if (log.text === '') throw new Error(`ENOENT: ${e.path}`)
      return { value: log.text }
    }
    const v = tape.answer('fs.read', e.path)
    if (typeof v !== 'string') throw new Error(`ENOENT: ${e.path}`)
    return { value: v }
  })
  on('fs.exists', (_$, e) =>
    LOG_PATH.test(e.path) ? { value: log.text !== '' } : { value: tape.answer('fs.exists', e.path) === true },
  )
  on('fs.write', (_$, e) => {
    if (LOG_PATH.test(e.path)) log.text = e.text
    return { value: undefined }
  })
  on('agent.spawn', (_$, e) => {
    beneath.push(e)
    return answer(e, beneath.length)
  })
}

function tapeIo(rec: Recording, tape: Tape): RouteIo {
  const cwd = rec.input.cwd ?? tape.text('session.cwd', '') ?? ''
  return {
    ...ioDirs(tape.text('env.get', 'CLAUDE_CONFIG_DIR'), tape.text('env.get', 'HOME'), cwd),
    read: async path => {
      const v = tape.answer('fs.read', path)
      return typeof v === 'string' ? v : null
    },
    exists: async path => tape.answer('fs.exists', path) === true,
  }
}

/** Registers the replay tests for `recordings`; an empty list is a failing test. */
export function replay(recordings: readonly Recording[]): void {
  test('there is at least one recording to replay', () => {
    if (recordings.length === 0) throw new Error('no recordings: nothing was replayed')
  })

  for (const rec of recordings) {
    const label = labelOf(rec)

    test(`${label}: decide() returns the expected type and model`, async () => {
      const tape = new Tape(rec.tape, label)
      const d = await decide(spawnInput(rec), tapeIo(rec, tape))
      expect(tape.misses).toEqual([])
      expect(d.subagentType).toBe(rec.expected.subagentType)
      expect(d.model ?? null).toBe(rec.expected.model)
      expect(d.action).toBe(rec.expected.action)
    })

    test(`${label}: the hooks module passes the expected spawn down and logs it once`, async ($, on) => {
      const tape = new Tape(rec.tape, label)
      const log: LogFile = { text: '' }
      const beneath: AgentSpawnInput[] = []
      standIns(on, tape, log, beneath, e => ({ model: e.model ?? 'definition', agentId: 'replay' }))

      await $.agent.spawn(spawnInput(rec))

      expect(tape.misses).toEqual([])
      expect(beneath.length).toBe(1)
      const down = beneath[0]
      expect(down?.subagentType).toBe(rec.expected.subagentType)
      expect(down?.model ?? null).toBe(rec.expected.model)
      const mine = logLinesFor(log.text, rec.input.tool_use_id)
      expect(mine.length).toBe(1)
      expect(mine[0]?.action).toBe(rec.expected.action)
      expect(mine[0]?.set).toEqual({ type: down?.subagentType, model: down?.model ?? null })
      expect(mine[0]?.error).toBe(undefined)
    })

    if (rec.expected.action !== 'rewrote' && rec.expected.action !== 'cleared-model') continue

    test(`${label}: a changed spawn the engine refuses runs once more as requested`, async ($, on) => {
      const tape = new Tape(rec.tape, label)
      const log: LogFile = { text: '' }
      const beneath: AgentSpawnInput[] = []
      standIns(on, tape, log, beneath, (e, n) =>
        n === 1 ? { deny: `Agent type ${e.subagentType} not found` } : { model: e.model ?? 'definition', agentId: 'replay' },
      )
      const toasts: string[] = []
      on('ui.toast', (_$, e) => {
        toasts.push(String(e.text))
        return { value: undefined }
      })

      const result = await $.agent.spawn(spawnInput(rec))

      const requested = { type: rec.input.subagentType, model: rec.input.model ?? null }
      expect(result.deny).toBe(undefined)
      expect(beneath.map(e => ({ type: e.subagentType, model: e.model ?? null }))).toEqual([
        { type: rec.expected.subagentType, model: rec.expected.model },
        requested,
      ])
      const mine = logLinesFor(log.text, rec.input.tool_use_id)
      expect(mine.length).toBe(1)
      expect(mine[0]?.action).toBe('fallback')
      expect(mine[0]?.set).toEqual(requested)
      expect(mine[0]?.error).toBe(undefined)
      expect(toasts.length).toBe(1)
    })
  }
}
