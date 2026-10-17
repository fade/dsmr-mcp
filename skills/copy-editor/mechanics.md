# Mechanics of technical prose

A reference for the copy-editor, read after SKILL.md and `stock-patterns.md`. Same scope: outward-facing
prose in work product (README, docs, docstrings and comments, commit, PR, issue and review text).
Agent-facing files are out of scope.

**Precedence (operator, 2026-10-17):** house rules (including Canadian spelling, section 12) >
Google developer documentation style guide > other guides (USU's engineering standards were the
comparison point). Every Google position below was read from its page on 2026-10-17; do not
attribute anything else to Google without reading it.

**Counting:** unlike stock patterns, these are consistency and correctness findings: report every
instance, except sentence length, which is a heuristic (section 11).

**Authority:** in docstrings and comments, flag only, never rewrite (SKILL.md authority limit). A code
identifier is never renamed by you; raise it as a question.

## 1. Abbreviations and acronyms

- Google: spell a term out on first mention with the abbreviation in parentheses, unless "the majority
  of your audience is likely to recognize and understand the term" (its examples: API, URL, HTML, RAM,
  file formats, units such as MB or GiB).
- Decide by the document's reader. Entry documents (README, introduction, installation) define MCP,
  SBCL, ASDF, WAL, PSS and similar on first use. A reference page whose reader arrived through those
  may assume them.
- Treat abbreviations as words for plurals ("APIs") and pick the article by pronunciation ("an SBCL
  image", "a SQL query").

## 2. Numbers

- Google: spell out zero through nine, numerals for 10 and above.
- Google: always numerals for technical quantities (memory, disk space, numbers of queries, usage
  limits), versions, page numbers, prices, and for any number under 10 in a sentence that also holds
  one of 10 or more.
- Google: spell out a number that opens a sentence, or better, rewrite so it comes later.
- Google: commas in numbers of four or more digits (1,000; 65,888,288). This overrides the SI
  convention of no separator.
- Google: a range takes a hyphen with no spaces ("3-7"), never an en dash. This agrees with the house
  dash rule.

## 3. Units

- Google: a space between number and unit ("64 GB"); nonbreaking where the format supports it.
  Money, percentages and angle degrees take no space.
- Google: use the byte system the technology uses. Binary KiB, MiB, GiB for powers of 1024, decimal
  kB, MB, GB for powers of 1000 (lowercase k). ⚠ Tools mislabel: `/proc/meminfo` prints "kB" for
  KiB. Quote a tool's output exactly; state the true unit in your own prose.
- Google: no hyphen when number and unit modify a noun ("200 GB disk") unless clarity needs one.

## 4. Tense

- Google: present tense for general behaviour ("The server sends an acknowledgment"). Future tense
  only for an action that happens later in time, never for how an unreleased feature will work, and
  no hypothetical "would".
- House: a commit body states the decision as an action taken ("I made enumeration signal") and the
  behaviour after it in the present ("You now get a condition"). That is the register table, not a
  tense shift to flag.

## 5. Pronouns and "this"

- Google: avoid a pronoun whose antecedent is unclear ("If you type text in the field, it doesn't
  change" becomes "the text doesn't change").
- Google: follow "this" and "these" with a noun ("Set this value to true").
- Flag a sentence or paragraph that opens with a bare "This" or "It" pointing back at a whole previous
  sentence. Name the thing.

## 6. Contractions

- Google: use common two-word contractions ("you're", "don't", "isn't", "can't"). Avoid nonstandard
  ones ("browser's" for "browser is") and three-word ones. USU's ban is overridden.

## 7. Commas and clauses

- **House: the Oxford comma, always** (operator, 2026-10-17: Canadian style). A list of three or more
  takes a comma before the final "and" or "or". Google agrees, but this stands on the house rule.
- Google: a comma before "which" opening a nonrestrictive clause. A restrictive clause takes "that"
  with no comma ("the core that the launcher built").

## 8. Headings

- Google: sentence case. Name the content, or for a procedure the task in the imperative
  (`stock-patterns.md` section 6 covers Wh-headings).

## 9. Inclusive and precise terms

- Google, from its inclusive-documentation page: allowlist (or a rewrite) for whitelist; parent node
  (or controller, for Jenkins) for master and replica for slave; placeholder for dummy; final check
  for sanity check; person-hours for man-hours; "doesn't respond" for "hangs". It says to avoid
  blacklist without naming a replacement: the house choice is denylist, or a rewrite.
- Google: remove subjective words that judge difficulty ("simple", "easy", "quick") and state the
  action or a result the reader can verify. House addition, from USU's filler list: "just".
- ⚠ A proper name stands: a branch literally named `master`, a library's own API term. Prose that
  chooses the word is the finding; quoting a name is not.

## 10. Lists and parallel structure

- Items in one list share a grammatical form. Procedure steps open with an imperative verb.
- Put a modifier next to what it modifies ("He bought a horse named Prince for his sister").

## 11. Sentence and paragraph length (heuristic)

- USU advises 10-20 words a sentence and 4-6 lines a paragraph. Shipped docs here measured a median of
  14-30 words a sentence on 2026-10-17, with up to half of sentences over 30 words in some documents.
- Flag a sentence over about 30 words in a procedure or reference page, and a paragraph carrying more
  than one idea. Do not flag length in a commit body or design rationale when the sentence carries one
  connected argument; splitting it into fragments is the stock-pattern defect instead.

## 12. Spelling: Canadian (house rule)

**Canadian spelling, in general** (operator, 2026-10-17). It is the author's own spelling, so US forms
are the ones he is likely to miss; Google's US spelling is overridden here. Canadian is not British:

- **-our, -re, -ce nouns:** colour, behaviour, favour, neighbour; centre, metre (the unit; a gas
  meter is still a meter), fibre; defence,
  offence; licence and practice as nouns, license and practise as verbs ("a licence file"; "licensed
  under the AGPL").
- **-ize, not -ise:** organize, recognize, realize, normalize (the Canadian Oxford Dictionary's
  preference). **-yze or -yse:** both are Canadian (the Language Portal of Canada notes a trend to
  -yze); accept either, never both in one document.
- **Doubled l before a suffix:** travelled, modelling, cancelled, labelled.
- **Others:** cheque, grey, catalogue, dialogue; "program" for both software and a schedule.
- ⚠ **Names keep their spelling.** A code identifier, keyword, filename, API field, CSS property,
  command or quoted output is never respelled: `:license` in an `.asd`, `LICENSE`, `color:`,
  `normalize-path`. Prose that chooses the word is the finding; quoting a name is not.
- Report every US form in prose, and every instance of mixed spelling within one document.

## Enforcement

The commit hook (`scripts/githooks/dsmr-workproduct-lint.sh` in dsmr-mcp) blocks long dashes and the
block-tier stock phrases, and warns on the rest. Nothing in this file is mechanically enforced; it is
review-only.
