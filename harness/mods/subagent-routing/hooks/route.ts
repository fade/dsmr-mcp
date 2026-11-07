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

/**
 * - `rewrote`: the agent type changed, or a gsd-executor spawn lost its per-call model.
 * - `cleared-model`: a specialist kept its type and lost its per-call model.
 * - `unchanged`: passed on as requested, nothing to change.
 * - `cannot-decide`: passed on as requested because the rules could not place it.
 * - `refused`: no agent starts; a gsd-executor spawn the rules cannot place, in
 *   a project whose config sets `planning.agents.specialized` true.
 */
export type Action = 'rewrote' | 'cleared-model' | 'unchanged' | 'cannot-decide' | 'refused'

/** The workflow a dispatch prompt came from, as far as its text shows. */
export type Shape = 'execute-phase' | 'quick' | 'quick-batch' | 'audit-fix' | 'other'

export type Decision = {
  action: Action
  subagentType: string
  /** Model to pass on; undefined lets the agent definition's own model apply. */
  model: string | undefined
  reason: string
  /** Kind of spawn: subagent, fork, resume, workflow or teammate. */
  kind: string
  shape: Shape
  /** Absolute path of the plan the prompt names, when one was found. */
  planPath: string | null
}

/** What the project's planning config says about routing. */
export type ProjectConfig = {
  /** The text was read and parses as a JSON object. */
  found: boolean
  /** `planning.agents.specialized === true`. */
  specialized: boolean
  /** `planning.agents.executor` when it is an agent name, else null. */
  executor: string | null
  /** `workflow.agent_hint_routing === false`. */
  routingOff: boolean
}

// The planning directory gsd-core reads, named once.
const PLANNING_DIR = '.planning'
const EXECUTOR = 'gsd-executor'
const SHELL_DEVELOPER = 'shell-developer'
const LISP_DEVELOPER = 'lisp-developer'
const AGENT_NAME = /^[a-z0-9][a-z0-9-]*$/
// A dispatch prompt's plan line: "- <path>-PLAN.md (Plan)", or "(Plan, authoritative)" and kin.
const PLAN_LINE = /^[ \t]*- (\S+-PLAN\.md)[ \t]+\(Plan/gm
// An absolute plan path anywhere, with one leading slash and no glob or
// expansion character. Before it: the text's start, whitespace, a parenthesis,
// an angle bracket, or an opening quote or backtick (one that itself follows
// the start, whitespace, a parenthesis, or an angle bracket, so a closing quote
// after a variable does not count). After -PLAN.md: the end, whitespace, a
// quote, a backtick, a parenthesis, an angle bracket, or one of `.,:;!?` that
// is followed by one of those.
const ABSOLUTE_PLAN =
  /(?<=^|[\s()<>]|(?:^|[\s()<>])[`'"])(\/(?!\/)[^\s`'"()<>*?[\]{}$]*-PLAN\.md)(?=$|[\s`'"()<>]|[.,:;!?](?:$|[\s`'"()<>]))/g
// execute-phase writes plan paths under the repository root it names PROJECT_ROOT.
const PROJECT_ROOT_REF = /^(\$\{PROJECT_ROOT\}|\$PROJECT_ROOT)\//
const PROJECT_ROOT_SET = /^[ \t]*PROJECT_ROOT=['"]?(\/[^'"\s]*)['"]?[ \t]*$/m
const AUDIT_FIX_OPENING = 'Fix finding '
const QUICK_BATCH_OPENING = 'Execute quick-batch item'

/**
 * Directories the decision needs, from the environment and the session.
 * Configuration falls back to `$HOME/.claude` when CLAUDE_CONFIG_DIR is unset.
 */
export function ioDirs(
  configEnv: string | undefined,
  homeEnv: string | undefined,
  projectDir: string,
): Pick<RouteIo, 'configDir' | 'projectDir' | 'homeDir'> {
  const home = homeEnv ?? ''
  const configDir = configEnv && configEnv !== '' ? configEnv : `${home}/.claude`
  return { configDir: trimSlash(configDir), projectDir: trimSlash(projectDir), homeDir: trimSlash(home) }
}

export function spawnKind(e: SpawnFacts): string {
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

/**
 * Distinct absolute paths ending in -PLAN.md anywhere in `prompt`, normalized,
 * in order of first appearance. None of these is one:
 * - a relative, tilde, `${PROJECT_ROOT}`, or glob path;
 * - a path that follows a variable or a closing quote;
 * - a name that runs on past -PLAN.md.
 */
export function absolutePlanPaths(prompt: string): string[] {
  const seen = new Set<string>()
  for (const m of prompt.matchAll(ABSOLUTE_PLAN)) {
    if (m[1] !== undefined) seen.add(normalizePath(m[1]))
  }
  return [...seen]
}

/** `path` with each `//` and `/./` collapsed to one slash. */
export function normalizePath(path: string): string {
  return path.replace(/\/(?:\.?\/)+/g, '/')
}

/**
 * Dispatch shape of `prompt`, given the first plan path it names (as written).
 */
export function dispatchShape(prompt: string, plan: string | null): Shape {
  const opening = prompt.trimStart()
  if (prompt.includes('[gsd:dispatch') || (plan !== null && /(^|\/)phases\//.test(plan))) return 'execute-phase'
  if (opening.startsWith(QUICK_BATCH_OPENING)) return 'quick-batch'
  if (opening.startsWith(AUDIT_FIX_OPENING)) return 'audit-fix'
  if (plan !== null) return 'quick'
  return 'other'
}

/**
 * Absolute, normalized form of `path`, or null when it starts with a tilde and
 * no home is known. A leading `${PROJECT_ROOT}/` takes the absolute value
 * `prompt` assigns to PROJECT_ROOT on a line of its own, else the project
 * directory.
 */
export function resolvePath(
  path: string,
  io: Pick<RouteIo, 'projectDir' | 'homeDir'>,
  prompt = '',
): string | null {
  if (PROJECT_ROOT_REF.test(path)) {
    const root = trimSlash(PROJECT_ROOT_SET.exec(prompt)?.[1] ?? io.projectDir)
    path = path.replace(PROJECT_ROOT_REF, `${root}/`)
  }
  if (path.startsWith('/')) return normalizePath(path)
  if (path.startsWith('~/')) return io.homeDir === '' ? null : normalizePath(`${io.homeDir}${path.slice(1)}`)
  return normalizePath(`${io.projectDir}/${path.replace(/^(\.\/)+/, '')}`)
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

/**
 * Routing fields of a planning config's text. Unreadable text, invalid JSON
 * or a value other than an object has `found` false and every field unset.
 */
export function parseConfig(text: string | null): ProjectConfig {
  let parsed: unknown = null
  if (text !== null) {
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
  }
  const agents = field(field(parsed, 'planning'), 'agents')
  const executor = field(agents, 'executor')
  return {
    found: typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed),
    specialized: field(agents, 'specialized') === true,
    executor: typeof executor === 'string' && AGENT_NAME.test(executor) ? executor : null,
    routingOff: field(field(parsed, 'workflow'), 'agent_hint_routing') === false,
  }
}

// A permission rule on one agent type: `Agent(<type>)`, or the older tool name `Task(<type>)`.
const AGENT_RULE = /^(?:Agent|Task)\((.*)\)$/
const PERMISSION_LISTS = ['deny', 'ask', 'allow'] as const

/**
 * The settings `permissions` rule that names agent type `target` and not
 * `requested`, as `permissions.<list> holds <rule>`; null when there is none.
 * A `permissions` value that is not an object, or a list that is not an
 * array, is reported in place of a rule. `*` in a rule's agent type matches
 * any run of characters.
 */
export function permissionRuleAgainst(permissions: unknown, target: string, requested: string): string | null {
  if (permissions === undefined || permissions === null) return null
  if (typeof permissions !== 'object' || Array.isArray(permissions)) return 'permissions is not an object'
  for (const list of PERMISSION_LISTS) {
    const rules = field(permissions, list)
    if (rules === undefined) continue
    if (!Array.isArray(rules)) return `permissions.${list} is not a list`
    for (const rule of rules) {
      if (typeof rule !== 'string') continue
      const content = AGENT_RULE.exec(rule.trim())?.[1]?.trim()
      if (content === undefined) continue
      if (globMatches(content, target) && !globMatches(content, requested)) return `permissions.${list} holds ${rule}`
    }
  }
  return null
}

function globMatches(pattern: string, name: string): boolean {
  const source = pattern
    .split('*')
    .map(part => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
    .join('.*')
  return new RegExp(`^${source}$`).test(name)
}

function field(value: unknown, key: string): unknown {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)[key]
    : undefined
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

function hasModel(model: string | null | undefined): model is string {
  return typeof model === 'string' && model !== ''
}

/** Text cut to `n` characters for a reason line. */
function clip(text: string, n = 80): string {
  return text.length > n ? `${text.slice(0, n)}...` : text
}

async function hasDefinition(name: string, io: RouteIo): Promise<boolean> {
  for (const definition of [`${io.configDir}/agents/${name}.md`, `${io.projectDir}/.claude/agents/${name}.md`]) {
    if (await io.exists(definition)) return true
  }
  return false
}

/**
 * Routing decision for one spawn, by these rules in order:
 *
 * 1. A fork, resume, workflow agent or teammate passes unchanged.
 * 2. gsd-executor: with no readable project config it is `cannot-decide`;
 *    with `workflow.agent_hint_routing` false it stays
 *    gsd-executor. Otherwise the prompt must name exactly one
 *    readable plan, on one or more plan lines (`- <path>-PLAN.md (Plan`)
 *    naming the same resolved path, or, with no plan line and no audit-fix
 *    opening, as a single distinct absolute path ending in -PLAN.md anywhere.
 *    Its `agent_hint` becomes the agent type, model cleared, when it is one
 *    of these and has an installed definition:
 *    - shell-developer;
 *    - gsd-executor;
 *    - the project executor.
 *    With no hint the project default applies. A prompt opening
 *    "Fix finding " with no plan takes the project default too.
 *    When `planning.agents.specialized` is true, the project default is
 *    `planning.agents.executor`; when that is unset, is not an agent name, or
 *    is not installed, the spawn cannot be placed. In any other project the
 *    default is gsd-executor. A specialist's model is cleared; gsd-executor's
 *    per-call model is cleared only when `planning.agents.specialized` is
 *    true, and kept otherwise. A spawn that cannot be placed once the config
 *    is read is `refused` when `planning.agents.specialized` is true, so no
 *    agent starts, and `cannot-decide` otherwise, passing exactly as
 *    requested.
 * 3. shell-developer, lisp-developer or the project executor keeps its type
 *    and loses any per-call model.
 * 4. Every other agent type passes unchanged.
 */
export function decide(input: SpawnFacts, io: RouteIo): Promise<Decision> {
  return route(input, io)
}

async function route(input: SpawnFacts, io: RouteIo): Promise<Decision> {
  const kind = spawnKind(input)
  let named = planPaths(input.prompt)
  let shape = dispatchShape(input.prompt, named[0] ?? null)
  const asRequested = (action: Action, reason: string, planPath: string | null = null): Decision => ({
    action,
    subagentType: input.subagentType,
    model: input.model,
    reason,
    kind,
    shape,
    planPath,
  })
  const setType = (subagentType: string, action: Action, reason: string, planPath: string | null): Decision => ({
    action,
    subagentType,
    model: undefined,
    reason,
    kind,
    shape,
    planPath,
  })
  // gsd-executor follows the leader only in a specialized project; any other
  // project keeps the model its own profile asked for. Call once `config` is read.
  const keepExecutor = (reason: string, planPath: string | null): Decision => {
    if (!hasModel(input.model)) return asRequested('unchanged', `${reason}; gsd-executor follows the leader`, planPath)
    if (!config.specialized) {
      return asRequested('unchanged', `${reason}; gsd-executor keeps the requested model ${input.model}`, planPath)
    }
    return setType(EXECUTOR, 'rewrote', `${reason}; per-call model ${input.model} cleared, gsd-executor follows the leader`, planPath)
  }

  if (kind !== 'subagent') return asRequested('unchanged', `a ${kind} spawn is not routed`)

  const config = parseConfig(await io.read(`${io.projectDir}/${PLANNING_DIR}/config.json`))
  const type = input.subagentType

  // A gsd-executor spawn the rules cannot place: refused in a specialized
  // project, passed on as requested in any other. `help` says what must
  // change; a function is called only for a refusal. Call once `config` is read.
  const unplaced = async (
    cause: string,
    help: string | (() => Promise<string>),
    planPath: string | null = null,
  ): Promise<Decision> => {
    if (!config.specialized) return asRequested('cannot-decide', cause, planPath)
    const text = typeof help === 'string' ? help : await help()
    return asRequested('refused', `${cause}; planning.agents.specialized is true, so it does not run as gsd-executor. ${text}`, planPath)
  }
  // Only a cause in the prompt itself is fixed by a new prompt.
  const RENAME_PLAN =
    'Name one plan as one line `- <absolute path>-PLAN.md (Plan)`, or as a single absolute path ending in ' +
    '-PLAN.md, set off by whitespace, quotes, a backtick, parentheses, or angle brackets, anywhere in the ' +
    'prompt (such as `<plan>/abs/path/01-02-PLAN.md</plan>`), then re-spawn.'
  const install = (agent: string): string =>
    `Install the ${agent} agent definition in ${io.configDir}/agents or ${io.projectDir}/.claude/agents; ` +
    'until then the spawn is refused.'

  const projectDefault = async (reason: string, planPath: string | null): Promise<Decision> => {
    const executor = config.executor
    if (!config.specialized) return keepExecutor(`${reason}; planning.agents.specialized is not true`, planPath)
    if (executor === EXECUTOR) return keepExecutor(`${reason}; the project executor is gsd-executor`, planPath)
    if (executor === null) {
      return unplaced(
        `${reason}; planning.agents.executor is unset or not an agent name`,
        `Set planning.agents.executor in ${PLANNING_DIR}/config.json to an installed agent; until then the spawn is refused.`,
        planPath,
      )
    }
    if (!(await hasDefinition(executor, io))) {
      return unplaced(`${reason}; project executor ${executor} has no installed definition`, install(executor), planPath)
    }
    return setType(executor, 'rewrote', `${reason}; project executor ${executor} on its own model`, planPath)
  }

  if (type === EXECUTOR) {
    if (!config.found) {
      return asRequested('cannot-decide', `no readable ${PLANNING_DIR}/config.json under ${clip(io.projectDir, 200)}`)
    }
    if (config.routingOff) return keepExecutor('workflow.agent_hint_routing is false', null)
    // One plan spelled two ways counts once: plan lines are compared resolved.
    const lineCount = new Set(named.map(p => resolvePath(p, io, input.prompt) ?? p)).size
    if (lineCount > 1) return unplaced(`the prompt names ${lineCount} plans`, RENAME_PLAN)
    if (named.length === 0) {
      if (input.prompt.trimStart().startsWith(AUDIT_FIX_OPENING)) {
        return projectDefault('an audit-fix finding names no plan', null)
      }
      const absolute = absolutePlanPaths(input.prompt)
      if (absolute.length > 1) {
        return unplaced(`the prompt names ${absolute.length} absolute plan paths and none on a plan line`, RENAME_PLAN)
      }
      if (absolute.length === 0) return unplaced('the prompt names no plan and is not an audit-fix finding', RENAME_PLAN)
      named = absolute
      shape = dispatchShape(input.prompt, named[0] ?? null)
    }

    const planPath = resolvePath(named[0] ?? '', io, input.prompt)
    if (planPath === null) {
      return unplaced(
        'the plan path needs a home directory and none is known',
        'Name the plan by its absolute path in place of the ~/ path; a ~/ path cannot be resolved here.',
      )
    }
    const text = await io.read(planPath)
    if (text === null) {
      return unplaced(
        `the plan ${clip(planPath, 200)} is not readable`,
        'The plan file must exist and be readable at that path before the spawn can run.',
        planPath,
      )
    }

    const hint = frontmatterValue(text, 'agent_hint')
    if (hint === null || hint === '') return projectDefault('the plan carries no agent_hint', planPath)
    const routable = [SHELL_DEVELOPER, EXECUTOR, ...(config.executor === null ? [] : [config.executor])]
    // Help names only installed specialists: a hint of gsd-executor would run the plan generic.
    const fixHint = async (): Promise<string> => {
      const installed: string[] = []
      for (const agent of routable) {
        if (agent !== EXECUTOR && !installed.includes(agent) && (await hasDefinition(agent, io))) installed.push(agent)
      }
      if (installed.length === 0) {
        return `No routable specialist has an installed definition. ${install(config.executor ?? SHELL_DEVELOPER)}`
      }
      const remove = config.executor !== null && installed.includes(config.executor)
      return (
        `Set the plan's agent_hint to ${installed.join(' or ')}` +
        `${remove ? ', or remove it to use the project executor' : ''}; until then the spawn is refused.`
      )
    }
    if (!AGENT_NAME.test(hint)) {
      return unplaced(`agent_hint ${JSON.stringify(clip(hint))} is not an agent name`, fixHint, planPath)
    }
    if (!routable.includes(hint)) {
      return unplaced(`agent_hint ${hint} is outside the routable set`, fixHint, planPath)
    }
    if (!(await hasDefinition(hint, io))) {
      return unplaced(`agent_hint ${hint} names no installed definition`, install(hint), planPath)
    }
    if (hint === EXECUTOR) return keepExecutor('agent_hint gsd-executor', planPath)
    return setType(hint, 'rewrote', `agent_hint ${hint}; model cleared so the definition's own model applies`, planPath)
  }

  if (type === SHELL_DEVELOPER || type === LISP_DEVELOPER || type === config.executor) {
    return hasModel(input.model)
      ? setType(type, 'cleared-model', `${type} runs on its own model; per-call model ${input.model} cleared`, null)
      : asRequested('unchanged', `${type} requested with no per-call model`)
  }

  return asRequested('unchanged', `${type} is not routed`)
}
