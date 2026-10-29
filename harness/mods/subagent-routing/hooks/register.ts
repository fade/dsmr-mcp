// Hooks: route each subagent spawn through decide() and log the outcome.
//
// Log: <config>/logs/subagent-routing/<session>.jsonl, one JSON line per spawn
// and one `loaded` line per session start. When SUBAGENT_ROUTING_CAPTURE names
// a directory, each spawn's input, io tape and decision are also written there
// as <tool_use_id>.json for replay.
//
// The spawn hook never denies: a decision that fails leaves the spawn
// unchanged, and a hook that fails passes the original spawn on.

import type { EngineInterface, Register } from 'claude-code'
import { decide, ioDirs, type Decision, type RouteIo } from './route'

const VERSION = '0.1.0'
const LOG_DIR = 'logs/subagent-routing'
const SAFE_NAME = /^[A-Za-z0-9_-]+$/

/** One engine call the decision depended on, with what it answered. */
export type TapeEntry = {
  op: 'env.get' | 'session.cwd' | 'session.id' | 'fs.read' | 'fs.exists'
  arg: string
  result: string | boolean | null
}

// $.fs has no append: every log write is a read and a whole-file write,
// serialized through this chain so concurrent spawns do not drop lines.
let logChain: Promise<void> = Promise.resolve()

function appendLine($: EngineInterface, path: string, record: unknown): Promise<void> {
  logChain = logChain
    .then(async () => {
      const before = await $.fs.read(path).then(
        t => (typeof t === 'string' ? t : ''),
        () => '',
      )
      await $.fs.write(path, `${before}${JSON.stringify(record)}\n`)
    })
    .catch(() => undefined)
  return logChain
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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const tape: TapeEntry[] = []
    const { config, home } = await configDirOf($, tape)
    const { configDir } = ioDirs(config, home, e.cwd)
    const session = await $.session.id()
    if (SAFE_NAME.test(session)) {
      const engine = await $.session.version().then(v => v.version, () => null)
      await appendLine($, `${configDir}/${LOG_DIR}/${session}.jsonl`, {
        ts: new Date().toISOString(),
        session,
        event: 'loaded',
        version: VERSION,
        claudeCode: engine,
      })
    }
    return result
  })

  on('agent.spawn', async ($, e, next) => {
    const capture = await $.env.get('SUBAGENT_ROUTING_CAPTURE')
    const tape: TapeEntry[] = []
    const { config, home } = await configDirOf($, tape)
    let cwd = e.cwd
    if (cwd === undefined) {
      cwd = await $.session.cwd()
      tape.push({ op: 'session.cwd', arg: '', result: cwd })
    }
    const dirs = ioDirs(config, home, cwd)

    let decision: Decision
    try {
      decision = await decide(e, tapedIo($, dirs, tape))
    } catch (err) {
      decision = {
        action: 'unchanged',
        subagentType: e.subagentType,
        model: e.model,
        reason: `decision failed: ${err instanceof Error ? err.message : String(err)}`,
        shape: 'error',
        planPath: null,
      }
    }

    const result =
      decision.action === 'rewrote'
        ? await next({ ...e, subagentType: decision.subagentType, model: decision.model })
        : await next(e)

    const session = await $.session.id()
    tape.push({ op: 'session.id', arg: '', result: session })
    const record = {
      ts: new Date().toISOString(),
      session,
      toolUseId: e.tool_use_id,
      parentAgentId: e.parentAgentId ?? null,
      requested: { type: e.subagentType, model: e.model ?? null },
      set: { type: decision.subagentType, model: decision.model ?? null },
      resolvedModel: result.deny === undefined ? result.model : null,
      agentId: result.deny === undefined ? (result.agentId ?? null) : null,
      denied: result.deny ?? null,
      action: decision.action,
      reason: decision.reason,
      shape: decision.shape,
      plan: decision.planPath,
    }
    if (SAFE_NAME.test(session)) {
      await appendLine($, `${dirs.configDir}/${LOG_DIR}/${session}.jsonl`, record)
    }

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
              source: { kind: 'hook', claudeCode: engine, capturedAt: record.ts },
            },
            null,
            2,
          )}\n`,
        )
        .catch(() => undefined)
    }

    return result
  }).catch(($, e, next) => next(e))
}
