// Routing decision for one subagent spawn.
//
// decide() reads the spawn's own fields and whatever the injected io answers,
// nothing else, so a recorded spawn and its io tape replay the same decision.

/** The fields of an `agent.spawn` input the decision reads. */
export type SpawnFacts = {
  subagentType: string
  model?: string
  prompt: string
  cwd?: string
  fork: boolean
  resume?: { agentId: string }
  workflow?: { runId: string; agentIndex: number }
  isTeammate?: true
}

/** File access and fixed directories the decision runs against. */
export type RouteIo = {
  /** Text of the file, or null when it is absent or unreadable. */
  read: (path: string) => Promise<string | null>
  exists: (path: string) => Promise<boolean>
  /** Claude Code configuration directory, absolute. */
  configDir: string
  /** Directory a relative plan path resolves against, absolute. */
  projectDir: string
  /** Home directory for a plan path written with a leading tilde; empty when unknown. */
  homeDir: string
}

export type Action = 'rewrote' | 'unchanged'

export type Decision = {
  action: Action
  subagentType: string
  /** Model to pass on; undefined lets the agent definition's own model apply. */
  model: string | undefined
  reason: string
  /** Kind of spawn: subagent, fork, resume, workflow or teammate. */
  shape: string
  /** Absolute path of the plan the prompt names, when one was found. */
  planPath: string | null
}

const EXECUTOR = 'gsd-executor'
const SHELL_DEVELOPER = 'shell-developer'
const AGENT_NAME = /^[a-z0-9][a-z0-9-]*$/
// A dispatch prompt's plan line: "- <path>-PLAN.md (Plan)", or "(Plan, authoritative)" and kin.
const PLAN_LINE = /^[ \t]*- (\S+-PLAN\.md)[ \t]+\(Plan/gm

/**
 * Directories the decision needs, from the environment and the session.
 * Configuration falls back to `$HOME/.claude` when CLAUDE_CONFIG_DIR is unset.
 */
export function ioDirs(
  configEnv: string | undefined,
  homeEnv: string | undefined,
  cwd: string,
): Pick<RouteIo, 'configDir' | 'projectDir' | 'homeDir'> {
  const home = homeEnv ?? ''
  const configDir = configEnv && configEnv !== '' ? configEnv : `${home}/.claude`
  return { configDir: trimSlash(configDir), projectDir: trimSlash(cwd), homeDir: trimSlash(home) }
}

export function spawnShape(e: SpawnFacts): string {
  if (e.fork) return 'fork'
  if (e.resume) return 'resume'
  if (e.workflow) return 'workflow'
  if (e.isTeammate) return 'teammate'
  return 'subagent'
}

/** Distinct plan paths named on plan lines of `prompt`, in order of first appearance. */
export function planPaths(prompt: string): string[] {
  const seen = new Set<string>()
  for (const m of prompt.matchAll(PLAN_LINE)) {
    if (m[1] !== undefined) seen.add(m[1])
  }
  return [...seen]
}

/** Absolute form of `path`, or null when it starts with a tilde and no home is known. */
export function resolvePath(path: string, io: Pick<RouteIo, 'projectDir' | 'homeDir'>): string | null {
  if (path.startsWith('/')) return path
  if (path.startsWith('~/')) return io.homeDir === '' ? null : `${io.homeDir}${path.slice(1)}`
  return `${io.projectDir}/${path.replace(/^(\.\/)+/, '')}`
}

/**
 * Value of `key` in the YAML frontmatter of `text` (between the first two `---`
 * lines), unquoted and without a trailing comment; null when the key is absent.
 * Reads top-level scalar keys only.
 */
export function frontmatterValue(text: string, key: string): string | null {
  const lines = text.split(/\r?\n/)
  if (lines[0]?.trim() !== '---') return null
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i] ?? ''
    if (line.trim() === '---') return null
    const m = /^([A-Za-z0-9_-]+):(.*)$/.exec(line)
    if (m !== null && m[1] === key) return scalar(m[2] ?? '')
  }
  return null
}

function scalar(raw: string): string {
  const v = raw.trim()
  const quote = v[0]
  if (quote === '"' || quote === "'") {
    const end = v.indexOf(quote, 1)
    return end > 0 ? v.slice(1, end) : v.slice(1)
  }
  if (v.startsWith('#')) return ''
  const comment = v.search(/\s#/)
  return (comment >= 0 ? v.slice(0, comment) : v).trim()
}

function trimSlash(dir: string): string {
  return dir.length > 1 ? dir.replace(/\/+$/, '') : dir
}

/**
 * Routing decision for one spawn. Covers one rule: a plain gsd-executor
 * subagent whose prompt names exactly one plan carrying
 * `agent_hint: shell-developer`, with a shell-developer definition installed,
 * becomes shell-developer with its model cleared. Every other spawn is left
 * unchanged and the reason says why.
 */
export function decide(input: SpawnFacts, io: RouteIo): Promise<Decision> {
  return route(input, io)
}

async function route(input: SpawnFacts, io: RouteIo): Promise<Decision> {
  const shape = spawnShape(input)
  const keep = (reason: string, planPath: string | null = null): Decision => ({
    action: 'unchanged',
    subagentType: input.subagentType,
    model: input.model,
    reason,
    shape,
    planPath,
  })

  if (shape !== 'subagent') return keep(`a ${shape} spawn is not routed`)
  if (input.subagentType !== EXECUTOR) return keep(`${input.subagentType} is not routed`)

  const named = planPaths(input.prompt)
  if (named.length === 0) return keep('the prompt names no plan')
  if (named.length > 1) return keep(`the prompt names ${named.length} plans`)

  const planPath = resolvePath(named[0] ?? '', io)
  if (planPath === null) return keep('the plan path needs a home directory and none is known')

  const text = await io.read(planPath)
  if (text === null) return keep('the plan is not readable', planPath)

  const hint = frontmatterValue(text, 'agent_hint')
  if (hint === null || hint === '') return keep('the plan carries no agent_hint', planPath)
  if (!AGENT_NAME.test(hint)) return keep('agent_hint is not an agent name', planPath)
  if (hint !== SHELL_DEVELOPER) return keep(`agent_hint ${hint} is not routed`, planPath)

  const definitions = [`${io.configDir}/agents/${hint}.md`, `${io.projectDir}/.claude/agents/${hint}.md`]
  for (const definition of definitions) {
    if (await io.exists(definition)) {
      return {
        action: 'rewrote',
        subagentType: hint,
        model: undefined,
        reason: `agent_hint ${hint}; model cleared so the definition's own model applies`,
        shape,
        planPath,
      }
    }
  }
  return keep(`agent_hint ${hint} names no installed definition`, planPath)
}
