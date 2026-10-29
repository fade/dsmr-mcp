// Hooks: route each subagent spawn through decide(), log the outcome, and
// answer /subagent-routing with what this session's spawns came to.
//
// Log: <config>/logs/subagent-routing/<session>.jsonl, one JSON line per spawn
// and one `loaded` line per session start. When SUBAGENT_ROUTING_CAPTURE names
// a directory, each spawn's input, io tape and decision are also written there
// as <tool_use_id>.json for replay.
//
// The spawn hook never denies. A spawn the rules cannot place, or one whose
// hook fails, proceeds exactly as requested; so does a changed spawn the
// engine refuses, run once more as requested (action `fallback`). The log
// line says why, and the first such spawn of each kind in a session raises a
// toast.

import type { EngineInterface, Register } from 'claude-code'
import { decide, ioDirs, type Action, type Decision, type RouteIo } from './route'

const VERSION = '0.2.0'
const LOG_DIR = 'logs/subagent-routing'
const SAFE_NAME = /^[A-Za-z0-9_-]+$/
const ERROR_TEXT_LIMIT = 200
/** Actions that raise a toast, once per session each. */
const LOUD: ReadonlySet<string> = new Set(['cannot-decide', 'fallback', 'error'])
const COUNTED = ['rewrote', 'cleared-model', 'unchanged', 'cannot-decide', 'fallback', 'error'] as const
/** When this module was registered; the status line falls back to it. */
const MODULE_LOADED_AT = new Date().toISOString()

/** `fallback`: the engine refused the changed spawn, so it ran as requested. */
type LogAction = Action | 'fallback' | 'error'
type Agent = { type: string; model: string | null }

/** One engine call the decision depended on, with what it answered. */
export type TapeEntry = {
  op: 'env.get' | 'session.cwd' | 'session.root' | 'session.id' | 'fs.read' | 'fs.exists'
  arg: string
  result: string | boolean | null
}

/** One line of the spawn log. */
export type SpawnLogLine = {
  ts: string
  session: string
  toolUseId: string
  parentAgentId: string | null
  shape: string
  plan: string | null
  requested: Agent
  set: Agent
  resolvedModel: string | null
  agentId: string | null
  action: LogAction
  reason: string
  version: string
  error?: { name: string; message: string }
}

// $.fs has no append: every log write is a read and a whole-file write,
// serialized through this chain so concurrent spawns do not drop lines.
let logChain: Promise<void> = Promise.resolve()

// What each in-flight spawn was passed down as, for the failure handler.
const passedDown = new Map<string, Agent>()

/** Appends `record` to `path`; resolves to the file's text before the append. */
function appendLine($: EngineInterface, path: string, record: unknown): Promise<string> {
  const step = logChain.then(async () => {
    const before = await $.fs.read(path).then(
      t => (typeof t === 'string' ? t : ''),
      () => '',
    )
    await $.fs.write(path, `${before}${JSON.stringify(record)}\n`)
    return before
  })
  logChain = step.then(
    () => undefined,
    () => undefined,
  )
  return step.catch(() => '')
}

function logLines(text: string): Record<string, unknown>[] {
  const lines: Record<string, unknown>[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      const v: unknown = JSON.parse(line)
      if (typeof v === 'object' && v !== null) lines.push(v as Record<string, unknown>)
    } catch {
      // A torn or foreign line is not counted.
    }
  }
  return lines
}

function logPath(configDir: string, session: string): string {
  return `${configDir}/${LOG_DIR}/${session}.jsonl`
}

function clip(text: string): string {
  return text.length > ERROR_TEXT_LIMIT ? text.slice(0, ERROR_TEXT_LIMIT) : text
}

async function configDirOf($: EngineInterface, tape: TapeEntry[]): Promise<{ config?: string; home?: string }> {
  const config = await $.env.get('CLAUDE_CONFIG_DIR')
  tape.push({ op: 'env.get', arg: 'CLAUDE_CONFIG_DIR', result: config ?? null })
  const home = await $.env.get('HOME')
  tape.push({ op: 'env.get', arg: 'HOME', result: home ?? null })
  return { config, home }
}

function tapedIo($: EngineInterface, dirs: Pick<RouteIo, 'configDir' | 'projectDir' | 'homeDir'>, tape: TapeEntry[]): RouteIo {
  return {
    ...dirs,
    read: async path => {
      const text = await $.fs.read(path).then(
        t => (typeof t === 'string' ? t : null),
        () => null,
      )
      tape.push({ op: 'fs.read', arg: path, result: text })
      return text
    },
    exists: async path => {
      const found = await $.fs.exists(path).catch(() => false)
      tape.push({ op: 'fs.exists', arg: path, result: found })
      return found
    },
  }
}

/**
 * Writes `line` to the session's log and, when its action is loud and no
 * earlier line of the session has that action, raises a toast.
 */
async function record($: EngineInterface, configDir: string, line: SpawnLogLine): Promise<void> {
  if (!SAFE_NAME.test(line.session)) return
  const path = logPath(configDir, line.session)
  const before = await appendLine($, path, line)
  if (!LOUD.has(line.action)) return
  if (logLines(before).some(l => l.action === line.action)) return
  const asRequested = line.set.type === line.requested.type && line.set.model === line.requested.model
  const what =
    line.action === 'fallback'
      ? 'ran a spawn as requested after the engine refused its change'
      : asRequested
        ? 'left a spawn as requested'
        : `passed a spawn on as ${line.set.type}, then failed`
  try {
    $.ui.toast(`subagent-routing ${what}: ${line.reason}. Log: ${path}`)
  } catch {
    // A surface with no toast still has the log line.
  }
}

/** The status line for /subagent-routing, counted from the session's log text. */
export function statusText(path: string, text: string): string {
  const lines = logLines(text)
  const loaded = lines.filter(l => l.event === 'loaded').at(-1)?.ts
  const spawns = lines.filter(l => typeof l.toolUseId === 'string')
  const count = (action: string): number => spawns.filter(l => l.action === action).length
  const [rewrote, cleared, unchanged, undecided, fellBack, failed] = COUNTED.map(count)
  return (
    `subagent-routing ${VERSION} loaded ${typeof loaded === 'string' ? loaded : MODULE_LOADED_AT}; log ${path}; ` +
    `this session: ${spawns.length} spawns, ${rewrote} rewrote, ${cleared} cleared-model, ` +
    `${unchanged} unchanged, ${undecided} cannot-decide, ${fellBack} fallback, ${failed} error`
  )
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.command
      .register({ name: 'subagent-routing', description: 'Show what subagent-routing did in this session' })
      .catch(() => undefined)
    const { config, home } = await configDirOf($, [])
    const { configDir } = ioDirs(config, home, e.cwd)
    const session = await $.session.id()
    if (SAFE_NAME.test(session)) {
      const engine = await $.session.version().then(v => v.version, () => null)
      await appendLine($, logPath(configDir, session), {
        ts: new Date().toISOString(),
        session,
        event: 'loaded',
        version: VERSION,
        root: $.plugin.root,
        claudeCode: engine,
      })
    }
    return result
  })

  on('command.run', { command: 'subagent-routing' }, async $ => {
    const { config, home } = await configDirOf($, [])
    const { configDir } = ioDirs(config, home, await $.session.cwd())
    const session = await $.session.id()
    const path = logPath(configDir, session)
    const text = SAFE_NAME.test(session)
      ? await $.fs.read(path).then(
          t => (typeof t === 'string' ? t : ''),
          () => '',
        )
      : ''
    return { text: statusText(path, text) }
  })

  on('agent.spawn', async ($, e, next) => {
    const capture = await $.env.get('SUBAGENT_ROUTING_CAPTURE')
    const tape: TapeEntry[] = []
    const { config, home } = await configDirOf($, tape)
    // A cwd the call sets is where the subagent runs; otherwise the project
    // root. A shell `cd` moves the session cwd, never the root.
    let projectDir = e.cwd
    if (projectDir === undefined) {
      projectDir = await $.session.root()
      tape.push({ op: 'session.root', arg: '', result: projectDir })
    }
    const dirs = ioDirs(config, home, projectDir)

    let decision: Decision
    let failure: { name: string; message: string } | undefined
    try {
      decision = await decide(e, tapedIo($, dirs, tape))
    } catch (err) {
      failure = {
        name: err instanceof Error ? err.name : typeof err,
        message: clip(err instanceof Error ? err.message : String(err)),
      }
      decision = {
        action: 'unchanged',
        subagentType: e.subagentType,
        model: e.model,
        reason: `the decision failed (${failure.name}: ${failure.message})`,
        kind: 'subagent',
        shape: 'other',
        planPath: null,
      }
    }

    const changes = decision.action === 'rewrote' || decision.action === 'cleared-model'
    const down = changes ? { ...e, subagentType: decision.subagentType, model: decision.model } : e
    passedDown.set(e.tool_use_id, { type: down.subagentType, model: down.model ?? null })
    let result = await next(down)
    let refused: string | undefined
    if (changes && result.deny !== undefined) {
      refused = result.deny
      passedDown.set(e.tool_use_id, { type: e.subagentType, model: e.model ?? null })
      result = await next(e)
    }
    const set: Agent =
      refused === undefined
        ? { type: decision.subagentType, model: decision.model ?? null }
        : { type: e.subagentType, model: e.model ?? null }

    const session = await $.session.id()
    tape.push({ op: 'session.id', arg: '', result: session })
    const line: SpawnLogLine = {
      ts: new Date().toISOString(),
      session,
      toolUseId: e.tool_use_id,
      parentAgentId: e.parentAgentId ?? null,
      shape: decision.shape,
      plan: decision.planPath,
      requested: { type: e.subagentType, model: e.model ?? null },
      set,
      resolvedModel: result.deny === undefined ? result.model : null,
      agentId: result.deny === undefined ? (result.agentId ?? null) : null,
      action: failure !== undefined ? 'error' : refused !== undefined ? 'fallback' : decision.action,
      reason:
        refused === undefined
          ? decision.reason
          : `${decision.reason}; the engine refused ${decision.subagentType} (${clip(refused)}), so it ran as requested`,
      version: VERSION,
      ...(failure === undefined ? {} : { error: failure }),
    }
    await record($, dirs.configDir, line)
    passedDown.delete(e.tool_use_id)

    if (capture !== undefined && capture !== '' && SAFE_NAME.test(e.tool_use_id)) {
      const engine = await $.session.version().then(v => v.version, () => null)
      await $.fs
        .write(
          `${capture.replace(/\/+$/, '')}/${e.tool_use_id}.json`,
          `${JSON.stringify(
            {
              input: { ...e },
              tape,
              decision: { ...decision, model: decision.model ?? null },
              source: { kind: 'hook', claudeCode: engine, capturedAt: line.ts },
            },
            null,
            2,
          )}\n`,
        )
        .catch(() => undefined)
    }

    return result
  }).catch(async ($, e, next) => {
    // next(e) replays the spawn the hook already passed on, or runs it as
    // requested when the hook failed before passing it on.
    const result = await next(e)
    try {
      const { config, home } = await configDirOf($, [])
      const { configDir } = ioDirs(config, home, e.cwd ?? (await $.session.cwd()))
      const session = await $.session.id()
      const name = next.error.kind
      const message = clip(next.error.message ?? '')
      const set = passedDown.get(e.tool_use_id) ?? { type: e.subagentType, model: e.model ?? null }
      passedDown.delete(e.tool_use_id)
      await record($, configDir, {
        ts: new Date().toISOString(),
        session,
        toolUseId: e.tool_use_id,
        parentAgentId: e.parentAgentId ?? null,
        shape: 'other',
        plan: null,
        requested: { type: e.subagentType, model: e.model ?? null },
        set,
        resolvedModel: result.deny === undefined ? result.model : null,
        agentId: result.deny === undefined ? (result.agentId ?? null) : null,
        action: 'error',
        reason: `the routing hook failed (${name}${message === '' ? '' : `: ${message}`})`,
        version: VERSION,
        error: { name, message },
      })
    } catch {
      // The spawn's result stands whether or not the line was written.
    }
    return result
  })
}
