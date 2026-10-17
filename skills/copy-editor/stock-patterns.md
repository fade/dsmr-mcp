# Stock patterns in technical prose

A reference for the copy-editor. Read SKILL.md first: the positive question (does this read as its
author writing about his own work?) and the register table come before anything here, and they
decide every conflict below.

The catalogue started from the list at tropes.fyi by ossama.is, which collects patterns readers have
learned to recognise as machine-written. I regrouped it by what each pattern costs the reader of
technical documentation and recorded where a pattern is legitimate in our material. The entries are
rewritten, not copied. Where an entry collides with a house rule, the house rule wins and the entry
says how to tell the two apart.

## Applying the catalogue

- **Scope: outward-facing prose in work product only.** README files, documentation, docstrings
  and comments, commit and PR text, issue and review comments. ⛔ Skill files and other
  agent-facing instructions are out of scope: they are structured for the agent reading them, and
  their glyphs, bold lead-ins and headings are not findings (operator, 2026-10-17).
- **Density decides most findings.** One instance of most of these patterns is just prose. Several
  together, or one repeated through a document, is the defect. Report a single instance only when you
  can name what it costs the reader in that sentence. The exception is cycling synonyms (section 5),
  which you flag at every instance.
- **The house bans stay absolute and are not repeated here.** Em and en dashes, "load-bearing",
  "human" for a person, planning indices, AI attribution: the mechanical audit blocks dashes and
  "load-bearing" in prose and messages and warns on them in source; "human" only warns.
- **The commit hook enforces part of this catalogue.** In prose files and commit messages it
  blocks the phrases with no legitimate use here ("delve", "tapestry", "it's worth noting", "in
  conclusion", "to sum up", "here's the catch", "let's dive in", "seamless", "game-changer",
  "ever-evolving"). It warns on words that are sometimes real terms ("robust", "leverage",
  "landscape", "serves as", "quietly") and blocks a commit message carrying three or more lines of
  them. Everything else here is review-only. ⚠ A passing hook is not a clean pass: density,
  structure, and every discriminator above still need you.
- **Name the cost, not the category.** "This sentence announces the answer instead of giving it"
  helps the author. Naming a pattern and calling it an AI tell does not: the author is a person,
  and the label says nothing about the sentence.
- **Docstrings and comments are flagged, never rewritten**, exactly as in SKILL.md. A pattern in a
  docstring is a question for the author.
- **A real technical term is never a finding.** "Test harness", "framework" naming a framework,
  "gate" naming a check that blocks something, "landscape" as a page orientation. Flag the
  ornamental use, where the word adds a tone and names nothing.

## 1. Patterns that delay or bury the answer

Technical readers arrive with a question and leave once it is answered. These patterns make them
read more to get the same answer.

- **Announcing instead of saying.** "Two constraints shape the design." "The more important point
  is where the decision sits." "Here's the catch." The sentence sets up the content instead of
  being it. Delete the announcement and start with the first constraint.
- **Stating the count before the list.** "Five things to know." The count is decoration unless the
  reader will check against it. ⚠ Legitimate in a procedure ("run these three commands") or a
  checklist, where the number tells the reader they are done.
- **Prose dressed as a list.** "The first issue is... The second issue is... The third..." If the
  points are parallel and separate, use a list. If they are not, write connected prose that says
  how they relate.
- **Evidence before the point.** A paragraph of supporting detail, then the question or claim it
  supports, so the point lands after it has already been made. Put the point first and keep only
  the evidence the reader needs to believe it.
- **Narrating the writing.** "I want to be precise about this." "What that changes is worth being
  exact about." This is the writer's deliberation left in the output.
  ⚠ **This is not the author's first person, which the register table requires.** The difference
  is the subject: "I made enumeration signal because..." is about the work and is correct; "I want
  to be clear that..." is about the sentence and is the defect. Ask whether the "I" decided
  something about the software or about the paragraph.
- **Defending a point nobody contested.** "I am setting this out in full rather than changing it
  quietly, because..." Justifying the act of writing it down. ⚠ A commit body owes the reader the
  why of the CHANGE. It never owes them the why of the sentence.
- **Summaries at every level.** An intro saying what the section will cover, the section, then a
  recap of the section. "In summary", "To sum up", "In conclusion". A reference page needs none of
  these, and a long guide needs at most one summary at the top.
- **Looping back to the question.** "So, to answer your question: yes." Stop when the answer has
  been given.
- **The ending that will not end.** Clause after clause, each adding a smaller afterthought. Pick
  the one point the reader should leave with and stop there.
- **One point restated many ways.** The same claim recast with fresh metaphors across sections, or
  a paragraph reappearing nearly verbatim. Keep the strongest statement, cut the rest.

## 2. Manufactured emphasis

These try to make an ordinary statement feel significant. In technical text they cost credibility:
a reader who notices the device starts discounting the claim it decorates.

- **"Not X, but Y."** "The issue isn't technical. It's organizational." The negated X is a claim
  nobody made, set up so Y can feel like a reveal. The tripled form ("Not a bug. Not a feature. A
  design flaw.") is the same device.
  ⚠ **Legitimate when X is what the reader would otherwise expect.** "Pass it a store it cannot
  read and you get a condition, not an empty list" is information: an empty list is exactly what a
  caller would assume. The test: would the reader have believed X without being told? If yes, the
  contrast carries information. If nobody thought X, it is the device.
- **Fragments stacked for drama.** "Flaky tests. A twenty-minute build. Two days for review." Short
  standalone sentences used as beats.
  ⚠ The dash rule recommends a full stop and a second sentence where a dash would have gone. That
  means a complete sentence, which is fine. The defect is a run of fragments standing in for
  connected thought.
- **Self-answered questions.** "The result? Devastating." "So what changed? Everything." Suspense
  before a point that needed none. State the point.
- **Triplets and repeated openings.** One tricolon reads fine. Three in a row, or four sentences
  opening with "They could...", reads as rhythm for its own sake. Vary the structure or collapse the
  series into one sentence. ⚠ Sentences chained on "I" have their own stricter threshold in
  SKILL.md's hunt list ("Chained first-person declaratives"): report them there, not again here.
- **The quotable line.** A standalone aphorism built to be lifted out ("Every metric that rewards
  volume punishes leverage"). If it carries no information a reader can act on, cut it.
- **A trailing clipped phrase.** A short phrase added after a comma to give the sentence a closing
  beat rather than information ("The build passes, finally."). Finish the thought in the main
  clause.
- **False ranges.** "From innovation to implementation to culture." "From X to Y" claims a scale
  with a meaningful middle. If there is no scale, list the things.

## 3. Inflated and empty words

- **Adverbs doing the work of evidence.** "Quietly", "deeply", "fundamentally", "remarkably",
  "arguably", "unusually well". Delete the adverb; if the sentence goes flat, the claim needed
  evidence the adverb was standing in for.
- **Ornamental nouns.** "Tapestry", "landscape", "paradigm", "synergy", and "ecosystem" or
  "framework" when no ecosystem or framework is meant. Use the plain word for the actual thing.
- **The stock vocabulary.** "Delve", "utilize", "leverage" as a verb, "robust", "streamline",
  "harness" as a verb, "certainly". Each has a plainer word: look into, use, use, reliable or
  specific, simplify, use; delete "certainly".
- **Avoiding "is".** "Serves as", "stands as", "represents", "marks" where "is" is meant. "The
  daemon serves as the broker" is "The daemon is the broker."
- **Filler transitions.** "It's worth noting", "Importantly", "Interestingly", "Notably", "It bears
  mentioning". If the next sentence matters, the reader will see that. Delete the transition, or
  say how the point connects to the previous one.
- **Promotional tone.** "Seamless", "unlocks", "all-in-one", "elevates". Documentation describes;
  it does not sell. State what the software does and let the reader judge.
- **Inflated stakes.** A configuration change described as reshaping how anyone works. Scale the
  claim to what the change does.
- **Tacked-on significance.** A trailing "-ing" clause asserting meaning: "...highlighting the
  importance of observability", "...reflecting broader trends". Cut it, or make the claim directly
  and support it.
- **Location as metaphor.** "Where the complexity actually lives." Name the module, the function,
  or the file.
- **The challenge-then-dismissal formula.** "Despite these challenges, the project continues to
  thrive." If a limitation matters, say what it is and what a reader should do about it.

## 4. Claims without a source

Technical readers act on claims, so a claim with no source is a risk to them, not a style problem.
The hunt list in SKILL.md already covers unanchored claims and overclaiming; these are the same
failure in conversational form.

- **Unnamed authorities.** "Experts argue", "industry reports suggest", "several projects have
  found". Name the source so a reader can check it, or make the claim on your own evidence, or drop
  it. Watch for one source inflated into many.
- **Borrowed familiarity.** "A classic", "famously", "notoriously", "as everyone knows". The
  reader's assumed knowledge stands in for a citation. If it is well known, the word adds nothing;
  if it is not, the word misleads.
- **Strings of historical analogies.** "Every shift, the web, mobile, cloud, followed this
  pattern." Authority by association. Make the argument about this software.
- **Invitations to imagine.** "Imagine a world where..." Describe what the software does now.
- **Performed candour.** "And yes, I'll admit I'm biased here." "This is not a rant." Polished
  self-disclosure that discloses nothing. If there is a real limitation or conflict, state it
  specifically.

## 5. Terms, names and figures

This group matters more in technical documentation than anywhere else, because a reader takes a new
word to mean a new thing.

- **Cycling synonyms for one referent.** The broker becomes the daemon, then the service, then the
  hub, within a page. ⭐ **In technical prose this is a correctness defect, not a style lapse:** the
  reader reasonably concludes there are four components. Pick one term per thing and repeat it.
- **Echoing a decorative phrase.** The same flourish reappearing later as if paying it off. The
  opposite rule from the one above: repeat technical terms exactly, never repeat decoration.
- **Coined labels used as established terms.** An abstract noun bolted to a domain word ("the
  supervision paradox", "workload creep") and then used as if the reader knew it. It names a thing
  in place of arguing it.
  ⚠ **A term defined at first use and used consistently is technical writing working as
  intended.** The test: is it defined where it first appears, and does it name something the reader
  will need to refer to again? If both, it is a term. If neither, it is a label.
- **Analogy as default.** "Think of it as a highway for data." "It's like a Swiss Army knife."
  Usually less clear than the thing itself, and patronising to a reader who came for the thing. Use
  an analogy only when the concept is unfamiliar and the analogy maps precisely.
- **Forced figures.** A simile or metaphor chosen because it sounds clever rather than because it
  clarifies. Say the literal thing. ⚠ A mind given to code ("the server sees", "the gate decides")
  is never weighed by density: it is a hunt-list finding in SKILL.md ("Code with a mind").

## 6. Headings, lists and typography

- **Wh-word headings.** "What it does", "Why it matters", "Where it runs". Use a heading that names
  the content ("Configuration", "Message delivery") or, for a procedure, the task in the imperative
  ("Install the server").
- **Title Case Headings.** Use sentence case: capitalise the first word and proper nouns only. This
  is also the Google developer documentation style guide's convention.
- **A bold lead-in on every bullet.** "**Performance**: lazy loading of..." on every item.
  ⚠ **A definition list is legitimate** (in org-mode, `- term :: description`) when the bold item IS
  the term being defined and the reader will scan for it. The defect is bold used to summarise the
  bullet's own sentence.
- **Characters a person does not type.** Unicode arrows (→), curly quotes, decorative symbols in
  shipped prose. Use `->` or a sentence, and straight quotes. ⚠ In docstrings and string literals a
  character change can change what a program emits: flag these, never substitute them.
- **"Let's" and the classroom voice.** "Let's break this down", "Let's dive in". The reader did not
  ask to be taught alongside; address them directly in the second person, per the register table.
- **"We" for a single author.** Already covered by the register table: the author's own first
  person is singular, and an agent's "we" is banned. The organisational "we" is acceptable only
  where an organisation is the author.
