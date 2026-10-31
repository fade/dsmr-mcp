// Replays recorded spawns against the routing decision and the hooks module.
//
// A recording is either what register.ts writes under SUBAGENT_ROUTING_CAPTURE
// (`source.kind` "hook") or what routing-probe.sh record-history builds from a
// session transcript (`source.kind` "transcript"): the spawn input, a tape of
// engine answers looked up by call and argument, and an `expected` block added
// by hand. Recordings hold real dispatch prompts, so they stay outside the
// repository; a test file written beside a temporary copy of the mod passes
// them in.

import { expect, test, type Engine } from 'claude-code/testing'
import type { AgentSpawnInput, AgentSpawnResult, On } from 'claude-code'
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

  has(op: TapeEntry['op'], arg: string): boolean {
    return this.entries.some(t => t.op === op && t.arg === arg)
  }

  text(op: TapeEntry['op'], arg: string): string | undefined {
    const v = this.answer(op, arg)
    return typeof v === 'string' ? v : undefined
  }
}

/**
 * The project root the hook asks the session for. A recording made before the
 * hook asked for the root holds the cwd it asked for instead.
 */
function rootOf(tape: Tape): string {
  return (tape.has('session.root', '') ? tape.text('session.root', '') : tape.text('session.cwd', '')) ?? ''
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

/** What the engine answers about agent types and permission rules in one test. */
type Offers = {
  /** isOffered per agent type the chain beneath answers; a type left out is offered. */
  isOffered?: Record<string, boolean>
  /** The settings' `permissions` value; a function that throws makes the read fail. */
  permissions?: () => unknown
  /** Session id in place of the recorded one, so no earlier test's offers apply. */
  session?: string
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
  offers: Offers = {},
): void {
  on('env.get', (_$, e) =>
    e.name === 'SUBAGENT_ROUTING_CAPTURE' ? { value: undefined } : { value: tape.text('env.get', e.name) },
  )
  on('session.cwd', () => ({ value: tape.text('session.cwd', '') ?? '' }))
  on('session.root', () => ({ value: rootOf(tape) }))
  on('session.id', () => ({ value: offers.session ?? tape.text('session.id', '') ?? '' }))
  on('agent.offer', (_$, e) => ({ isOffered: offers.isOffered?.[e.agent] ?? offeredOnTape(tape, e.agent) ?? true }))
  on('settings.read', () => {
    const permissions = offers.permissions === undefined ? permissionsOnTape(tape) : offers.permissions()
    return { value: permissions === undefined ? {} : { permissions } }
  })
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

/** The recorded isOffered answer for `type`, when the recording holds one. */
function offeredOnTape(tape: Tape, type: string): boolean | undefined {
  if (!tape.has('agent.offered', type)) return undefined
  const v = tape.answer('agent.offered', type)
  return typeof v === 'boolean' ? v : undefined
}

/** The recorded settings `permissions` value, when the recording holds one. */
function permissionsOnTape(tape: Tape): unknown {
  const text = tape.has('settings.permissions', '') ? tape.text('settings.permissions', '') : undefined
  return text === undefined ? undefined : (JSON.parse(text) as unknown)
}

/**
 * Raises the spawn as a dispatch does: the engine offers each agent type the
 * call can dispatch, then runs agent.spawn. `types` are the types offered.
 */
async function dispatch($: Engine, input: AgentSpawnInput, types: readonly string[]): Promise<AgentSpawnResult> {
  for (const agent of new Set(types)) {
    await $.agent.offer({ agent, description: '', source: 'userSettings', provider: { plugin: 'user', tier: 'user' } })
  }
  return $.agent.spawn(input)
}

function tapeIo(rec: Recording, tape: Tape): RouteIo {
  const projectDir = rec.input.cwd ?? rootOf(tape)
  return {
    ...ioDirs(tape.text('env.get', 'CLAUDE_CONFIG_DIR'), tape.text('env.get', 'HOME'), projectDir),
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

      await dispatch($, spawnInput(rec), [rec.input.subagentType, rec.expected.subagentType])

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
    const requested = { type: rec.input.subagentType, model: rec.input.model ?? null }

    if (rec.expected.subagentType !== rec.input.subagentType) {
      const target = rec.expected.subagentType
      const passesAsRequested = async (
        $: Engine,
        on: On,
        offers: Offers,
        types: readonly string[],
        why: string,
      ): Promise<void> => {
        const tape = new Tape(rec.tape, label)
        const log: LogFile = { text: '' }
        const beneath: AgentSpawnInput[] = []
        standIns(on, tape, log, beneath, e => ({ model: e.model ?? 'definition', agentId: 'replay' }), offers)
        const result = await dispatch($, spawnInput(rec), types)
        expect(result.deny).toBe(undefined)
        expect(beneath.map(e => ({ type: e.subagentType, model: e.model ?? null }))).toEqual([requested])
        const mine = logLinesFor(log.text, rec.input.tool_use_id)
        expect(mine.length).toBe(1)
        expect(mine[0]?.action).toBe('cannot-decide')
        expect(mine[0]?.set).toEqual(requested)
        expect(String(mine[0]?.reason)).toContain(why)
      }

      test(`${label}: a retype to a type this session was never offered passes as requested`, async ($, on) => {
        await passesAsRequested($, on, { session: 'replay-never-offered' }, [rec.input.subagentType], 'has not been offered')
      })

      test(`${label}: a retype to a type a permissions.deny rule names passes as requested`, async ($, on) => {
        await passesAsRequested(
          $,
          on,
          { session: 'replay-denied', permissions: () => ({ deny: [`Agent(${target})`] }) },
          [rec.input.subagentType, target],
          `permissions.deny holds Agent(${target})`,
        )
      })
    }

    test(`${label}: a changed spawn a hook beneath refuses runs once more as requested`, async ($, on) => {
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

      const result = await dispatch($, spawnInput(rec), [rec.input.subagentType, rec.expected.subagentType])

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

    test(`${label}: a spawn refused changed and as requested is logged as starting nothing`, async ($, on) => {
      const tape = new Tape(rec.tape, label)
      const log: LogFile = { text: '' }
      const beneath: AgentSpawnInput[] = []
      standIns(on, tape, log, beneath, (e, n) => ({ deny: `refusal ${n} of ${e.subagentType}` }))
      const toasts: string[] = []
      on('ui.toast', (_$, e) => {
        toasts.push(String(e.text))
        return { value: undefined }
      })

      const result = await dispatch($, spawnInput(rec), [rec.input.subagentType, rec.expected.subagentType])

      expect(result.deny).toBe(`refusal 2 of ${rec.input.subagentType}`)
      expect(beneath.length).toBe(2)
      const mine = logLinesFor(log.text, rec.input.tool_use_id)
      expect(mine.length).toBe(1)
      expect(mine[0]?.action).toBe('refused')
      expect(mine[0]?.resolvedModel).toBe(null)
      expect(mine[0]?.agentId).toBe(null)
      expect(String(mine[0]?.reason)).toContain('so no agent started')
      expect(String(mine[0]?.reason)).not.toContain('ran as requested')
      expect(toasts.length).toBe(1)
      expect(toasts[0]).toContain('started no agent')
      expect(toasts[0]).not.toContain('ran a spawn')
    })
  }
}
