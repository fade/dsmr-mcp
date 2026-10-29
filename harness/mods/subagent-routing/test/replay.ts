// Replays recorded spawns against the routing decision and the hooks module.
//
// A recording is what register.ts writes under SUBAGENT_ROUTING_CAPTURE: the
// spawn input, the tape of engine calls the decision depended on, the decision
// made at the time, plus an `expected` block added by hand. Recordings hold
// real dispatch prompts, so they stay outside the repository; a test file
// written beside a temporary copy of the mod passes them in.

import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput } from 'claude-code'
import type { TapeEntry } from '../hooks/register'
import { decide, ioDirs, type RouteIo } from '../hooks/route'

export type Recording = {
  input: AgentSpawnInput
  tape: TapeEntry[]
  decision: unknown
  expected: { subagentType: string; model: string | null; why: string }
  source: { kind: string; claudeCode: string | null; capturedAt: string }
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
      const d = await decide(rec.input, tapeIo(rec, tape))
      expect(tape.misses).toEqual([])
      expect(d.subagentType).toBe(rec.expected.subagentType)
      expect(d.model ?? null).toBe(rec.expected.model)
    })

    test(`${label}: the hooks module passes the expected spawn down`, async ($, on) => {
      const tape = new Tape(rec.tape, label)
      let beneath: AgentSpawnInput | undefined

      on('env.get', (_$, e) =>
        e.name === 'SUBAGENT_ROUTING_CAPTURE' ? { value: undefined } : { value: tape.text('env.get', e.name) },
      )
      on('session.cwd', () => ({ value: tape.text('session.cwd', '') ?? '' }))
      on('session.id', () => ({ value: tape.text('session.id', '') ?? '' }))
      on('fs.read', (_$, e) => {
        // The routing log is not part of the decision: it reads as empty.
        if (LOG_PATH.test(e.path)) return { value: '' }
        const v = tape.answer('fs.read', e.path)
        if (typeof v !== 'string') throw new Error(`ENOENT: ${e.path}`)
        return { value: v }
      })
      on('fs.exists', (_$, e) => ({ value: tape.answer('fs.exists', e.path) === true }))
      on('fs.write', () => ({ value: undefined }))
      on('agent.spawn', (_$, e) => {
        beneath = e
        return { model: e.model ?? 'definition', agentId: 'replay' }
      })

      await $.agent.spawn({ ...rec.input })

      expect(tape.misses).toEqual([])
      expect(beneath?.subagentType).toBe(rec.expected.subagentType)
      expect(beneath?.model ?? null).toBe(rec.expected.model)
    })
  }
}
