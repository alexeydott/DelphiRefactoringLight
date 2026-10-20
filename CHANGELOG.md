# Changelog

Every released version of Delphi Refactoring Light, newest first. Each entry
links to the full notes of that release. Versions before 1.7.0 were
development builds and were never released.

---

## 2.2.0 - 2026-10-20

### The settings, by name - permanently or for this IDE only

The plugin's options were reachable only through its page in Tools >
Options, which a Claude Code session cannot click. The new `settings` tool
lists all fifteen with their current value, their default, their range or
choices and what they do - and sets one by name. `scope` decides how long
it holds: `permanent` writes the registry (this IDE and every one started
later), `session` changes it for the RUNNING IDE only. There is no default
scope on purpose: a change that may outlive the IDE is not one to guess at.

"Session only" means it: the registry keeps the value it had, and a `Save`
triggered anywhere else - the rename dialog storing its scope, the uses
cleanup its keep list - writes that old value rather than the temporary
one. `Save` is driven by the same descriptor the tool lists, so a setting
can no longer be in one place and missing from the other (two hand-kept
lists are what made the legacy migration drop five values).

### `lsp_restart`

Closing and reopening a project does not restart the plugin's DelphiLSP
session, so a session that has gone wrong - typically because it loaded
`.dcu` files instead of sources - could only be fixed by restarting the
IDE. `lsp_restart` ends it (the verification session with it); the next
request that needs DelphiLSP starts a fresh one.

### An empty LSP answer, corrected

2.1.1 said that a unit the session HAS analysed cannot be a `.dcu`
problem. A session log then showed otherwise: hover answered at the very
position, and the symbol's DECLARING unit had been loaded from a stale
`.dcu`, so the compiler reported its definition without a file. Both
causes are named now, with the log line that tells them apart
(`definition found in file:///(-1:0)`).

## 2.1.1 - 2026-10-19

### An empty LSP answer names the right cause

When an `lsp_*` tool answered nothing, the note always blamed a precompiled
`.dcu` as the "usual cause" - and in the case a reviewing session actually
hit, `lsp_hover` ANSWERED at that very position and only the definition was
unresolved, so the hint pointed at the wrong place and never mentioned
`find_original_symbol`, which does answer there. The note is derived now:
when the session has analysed the unit, it says that this is about the
POSITION (the private/public overload pair of Delphi 13.1 RSS-5463 is the
known case) and names `find_original_symbol`; only for a unit it has
analysed nothing of does the `.dcu` paragraph and the log recipe appear.
Fixed with it, a regression of 2.0.6: the tool's own sentence and the
generic text both opened with "DelphiLSP returned nothing", so the note read
"DelphiLSP returned nothing for this position. DelphiLSP returned nothing.
If ...". The text is one pure rule with a test now.

## 2.1.0 - 2026-10-19

### A "guide" tool: what this server can do, in one call

A fresh Claude Code session sees the tool NAMES and the always-loaded
instructions - 946 characters, deliberately no catalogue, because every
session pays for them whether it calls a tool or not. What it could not get
anywhere was the overview: which tool for which job, and the three rules
that cost a round when you do not know them (the IDE buffer is the truth,
`apply=false` first, an id or token belongs to ONE answer).

`guide` answers exactly that as plain text, grouped by job and covering
every tool. It takes no arguments, changes nothing, and - unlike every other
tool here - it needs **no running IDE**: the bridge answers it itself, so a
session that starts before the IDE is up can read it. It costs nothing until
it is called, which is why it may be as long as it is useful (~2 500 tokens)
while the instructions stay short.

The guide cannot go stale unnoticed: a test holds it against the shipped
tool definitions in all three directions - every tool in exactly one
section, no section naming a tool that does not exist, and every name
really present in the prose that section shows. It found its first defect
immediately: the `lsp_*` section described the tools without naming them.

## 2.0.6 - 2026-10-19

### An answer carries no key twice

An empty `lsp_hover` answer had the key `"note"` TWICE: one place added the
freshness diagnosis, the next line added its own sentence. That is valid
JSON of which a parser keeps one pair - its choice - so one of the two
sentences was lost at random. The two sentences are ONE note now, and in the
`lsp_*` tools every note goes through a helper that REPLACES, so a second
one cannot become a second key. A sweep over the whole unit was the evidence
that `lsp_hover` was the only such place; the four tools whose note is
purely informational were converted with it, and they now add the reason
when their answer is empty - the hint `lsp_definition` and `lsp_hover`
already gave.

### Which unit need not be open

`find_original_symbol` named "a unit that is not open" as a case the `lsp_*`
tools cannot answer, while those tools say the unit need not be open - a
contradiction in wording, not in substance: the tools send the unit you ASK
ABOUT, and what can stay invisible to them is the unit a symbol is DECLARED
in. Both sentences name their unit now.

## 2.0.5 - 2026-10-19

### An apply says what it really did

`interface_guids` and `dfm_events` had a fixed note for `apply=true`, so an
apply whose ids matched nothing at all still answered "The declarations you
named carry a fresh GUID now" - measured live, with `unknownIds` naming the
id right next to it. Both tools derive the sentence from the outcomes now,
in one shared place: how many were done, how many failed, how many ids
matched no finding - and "NOTHING was changed" when that is the truth. They
also report `fixed` / `notFixed` as numbers, like the two project checks that
had it right.

## 2.0.4 - 2026-10-19

### A unit with no source is a finding, not a gap

Measured on the project of the report that produced the check's
`no_source_found` kind: the row said "the project lists a unit that is not
there", while the notes above it counted the same unit among those that
"could not be read" - one answer contradicting itself, and the half-answer
the kind was introduced to avoid. The two cases have their own sentence now:
a file that is there and unreadable was not checked, a unit with no file at
all is reported below as a finding (with the one place the check cannot look
named: a path only the compiler knows).

## 2.0.3 - 2026-10-19

A reviewing model was given the MCP server with nothing but the tool list and
asked whether it could use the tools from the descriptions alone. It could,
for almost everything - and the two gaps it named are fixed here. Nothing in
the IDE changes; this is about what an agent can know before it calls.

### The rules file of `semantic_replace` is described in the tool itself

The format of `<project root>\semantic-replace.json` was nowhere in the MCP
surface, so an agent could run existing rules but never write one. The tool
now carries the shape (`find`, `replace`, `uses` as an array, `declaredIn`,
the optional `localVar` block), what the match does and does not do (dotted
identifier paths, not regular expressions; case-insensitive; never inside a
comment or a string; a rule without `find` is dropped), and that the file is
plain JSON rather than a Delphi source.

### Every writing tool says what protects its `apply`

The shared `apply` text ended with "plus a token" - and only 9 of the 23
writing tools hand one out, so for the rest it was impossible to tell from
the outside whether an apply is protected against a file that moved on. Each
of them now names its own guard:

- **a token** (9 tools): the preview pins the files *and* the arguments.
- **it looks again** (8): `apply` re-runs the tool's own analysis on the
  current buffers, so a plan made for a state that is gone cannot be carried
  out.
- **the ids of a scan** (4): `apply` re-scans and acts on the `fix_ids` you
  name; an id names the PLACE, so an old one finds nothing rather than
  something else.
- **it compares** (2): `apply` reads the files again and refuses when they
  differ from what was analysed.

A contract test walks the shipped list and fails on a tool that promises a
token it has no parameter for, or that says "no token" without naming what it
does instead. That sweep found five more writing tools the report could not
see, because their `apply` text was written per tool instead of shared -
among them `convert_properties`, whose `apply` had no description at all.

### Every parameter says what it is

Six parameters were named in the review as undocumented; the sweep that
checks it found **46** of 219 - among them the `apply` of
`convert_properties`, which had no description at all. All of them carry one
now, written from the handler with the default it really uses: `find_unit`
`partial`/`max`, `rename_preview` `scope` (project, unit or method - there
is no "selected"), `include_open_units`/`include_used_units`,
`convert_properties` `direction`/`getter`/`setter`/`to_line`, `uses_cycles`
`unit`/`max`, `blame` `start_line`/`end_line`, `commit_info` `diff_file`,
`lsp_references` `include_declaration`, `lsp_completion` `prefix`/`max`,
`lsp_request` `method`/`params`/`timeout_ms`, and the rest.

### Three answers the descriptions did not give

- **How a column counts**: "1-based" does not say what happens to a tab or
  to a character outside ASCII. Every `column` and `end_column` says it now:
  characters of the line as stored, a tab counts as ONE, not as its width on
  screen.
- **Whether `lsp_*` needs an open unit**: it does not. Each of the eight
  tools says that it reads the file (editor buffer first, else disk), sends
  that text to the session and waits for its analysis - and that it cannot
  make DelphiLSP resolve a unit its own compile does not reach, where
  `find_original_symbol` is the fallback that asks the identifier index.
- **What `edit_method` moves**: the routines a class declares. A field or a
  property is never listed and never moves, so a method that uses one leaves
  it behind - which the answer already named, without the description ever
  saying so. (The record comment in the source claimed "property / field"
  too; it was wrong and is corrected.)

### An id that matches nothing is said out loud

`interface_guids` and `dfm_events` ignored a `fix_ids` entry that matched no
finding, while their note said the places you named are done - the same
defect the line-ending check had in 1.25.1, in the one answer a caller cannot
check. Both report `unknownIds` now.

### Downloads

The same three files as 2.0.1: the package for the 32-bit and the 64-bit IDE,
and the MCP bridge.

---

## 2.0.1 — 2026-10-17

Everything since 1.23.2 (versions 1.23.3 … 2.0.1, 37 commits). The major
number changes because of one behaviour change, at the end of this entry.

### Downloads

The compiled package is attached to this release, so a team can roll it out
without building anything (issue #48):

| file | for |
| --- | --- |
| `DelphiRefactoringLight370-Win32.bpl` | the 32-bit IDE (`bin\bds.exe`) |
| `DelphiRefactoringLight370-Win64.bpl` | the 64-bit IDE (`bin64\bds.exe`) |
| `RefactoringLightMcp.exe` | the MCP bridge for Claude Code (optional) |

Both packages are built Release for RAD Studio 13 (37.0). Load one through
*Component > Install Packages*, or replace the file your team already loads.
Installing from the sources with `install.cmd` stays the normal way: it also
registers the package, builds and registers the bridge, and works on machines
without a command-line compiler. The detailed `.map` files are not attached by
default — ask for them when an address from a crash log has to be resolved,
because that needs the map of exactly this build.

### New

**Declare as constant** — editor menu, `Ctrl+Alt+Shift+C`, MCP tool
`declare_constant`. Select a number or a string and declare it as a `const` or
a `resourcestring`: local, in the class, or at unit level, optionally replacing
every other occurrence in the routine or the unit. The dialog checks live — the
preview line either shows the declaration that would be written or says in red
why it cannot be, so there is no second code path that could disagree with the
apply. It also opens with nothing selected, to define a constant from scratch.
A value that names an identifier is refused: that name need not be in scope
where the declaration goes.

**Project check "Line endings"** — and a warning the moment the IDE *opens* a
file with LF-only or mixed line endings, with "correct now", "this session" or
"always". Delphi copes badly with mixed endings, and the open is the right
moment: nothing has been typed yet, so the file can simply be rewritten and
re-read. Form files, binaries and anything inside the RAD Studio installation
are never touched. Measured on a real project: 25 findings in 2000 files, one
of them genuinely mixed (1035 CRLF + 55 LF).

**Project check "File encoding"** — the default pair is the one that fixes a
real defect: a source that is valid UTF-8 but carries **no BOM** is read by the
compiler as ANSI, so every non-ASCII character silently becomes two (measured
with dcc32 37.0). Pure ASCII is never a finding — its bytes are the same in
every encoding — and form files are left alone, because the IDE writes a
non-ASCII character as `#nnnn` anyway (measured: 1368 of 1381 form files of a
real project are pure ASCII).

**Project check "Unused project units"** (issue #47) — units the project file
lists although nothing in the project names them any more. A unit counts as
used when any other unit uses it (units on the search path included) or when
the project body names one of its identifiers, which is how a form reached only
through `Application.CreateForm` is used. Two kinds: *unused*, and *unused, has
initialization* — the latter a hint, because such a unit is often in the project
exactly to register itself. Read-only: it never edits the project file. Measured
on a real project: 86 findings in 1822 units.

Four new MCP tools, 56 → **60**: `declare_constant`, `line_endings`,
`file_encoding`, `unused_units`.

### Extract interface

Four reports, all of them from real classes:

- a **wrapped parameter list** was cut at the `;` inside it, and the
  continuation line came back as a "field"; an **`&`-escaped name**
  (`property &String`) parsed as empty (#44);
- an **array property** lost its index list, and whether its accessor is a field
  or a method was decided by the name starting with `Get`/`Set` instead of by
  the class's own member list (#46);
- the interface unit no longer copies the source unit's **whole uses clause** —
  it takes only what the generated interface really needs, which is the point of
  extracting an interface in the first place;
- an **existing target unit** is extended now (the interface is added at the end
  of its type block, its uses clause topped up) instead of asking whether to
  overwrite the file.

And the command now says whether the class **can implement an interface at
all** — a `TObject` descendant provides no `IInterface`, so the extracted
interface would not compile — and offers to fix it right there: derive from
`TInterfacedObject`, or add the `IInterface` implementation to the class itself.
Neither is preselected: both change how the instance is freed.

### The MCP bridge replaces itself

Windows cannot overwrite a running program, so an install while Claude Code was
running used to leave that session on the old bridge for good. A bridge of
1.33.0 or newer notices **between two requests** that an install has moved it
aside, starts the installed exe on its own stdin/stdout and waits for it: the
session keeps talking to the same process it started, while the new code
answers. Aside copies of earlier installs are removed at the next start.

### Installing

A run of reports from machines with no command-line compiler, or where Delphi
was installed by a different account:

- the install set an environment variable named `CONFIG`, and **MSBuild reads
  every environment variable as a property**, so `$(Config)` became the path of
  the config file and the build died trying to create a directory from it;
- a `bds.exe` build that printed a **fatal error reported success**, because
  bds.exe exits 0 either way. The error file has the last word now, decided by
  the compiler code rather than the localized severity word;
- the **MCP bridge is built by the installer itself**, as one row in the same
  summary — including through the IDE on machines where msbuild is not
  available, where the bridge was simply never built before;
- the package registration is **suspended during a bds build**, so the IDE
  started for the build neither reports a missing BPL nor locks the file the
  linker is about to write;
- msbuild is pinned to toolset 4.0 (a machine whose default was 2.0 failed with
  MSB4036);
- when the common directory belongs to another account, the build output goes to
  `%LOCALAPPDATA%` instead of failing with MSB3191;
- the install window could not be closed: a dialog watcher outlived the install
  and kept the console alive. It ends by itself now, and only ever watches the
  IDE it started.

### Behaviour change (this is what makes it 2.0)

A write to an editor buffer **from a worker thread now raises** a named
exception instead of only being counted. ToolsAPI and the editor buffers are
main-thread only; breaking that rule does not fail, it corrupts a buffer now and
then — the worst way for a defect to behave. The flip had a condition written
down when the counter was introduced: one live round over the write paths in
which the counter stays at zero. That round ran before the flip.

### Fixes

- **Nested routines declared before a method's `begin` hid the method itself**
  from the enclosing-routine walk — which feeds declare-as-constant, extract
  variable, the rename scope "in current method" and the source resolution of
  find references and rename. A sweep over 344 files: 21,201 lines newly
  attributed to their routine, not one range changed.
- No check ever rewrites a file of the **RAD Studio installation** (an Indy
  source open in the editor was offered for conversion).
- The editor menu's refactorings are **two alphabetical blocks** now — "introduce
  something new" and "change what is there"; Remove with and Expand include
  files moved to the project-wide group they share a scope dialog with.
- **"Go to"** selects the identifier instead of marking from the start of the
  line (interface GUID check, DFM event check), and in Unused project units it
  points at the entry in the `.dpr` for a unit that has no file at all.
- A message about a write **says where the write went** — the editor buffer
  (undoable) or the disk. For a project-wide check most files are not open.
- Result windows: **Close really closes**, and the shared progress window paints
  its text before the scan starts instead of standing there empty.
- An MCP handler stuck in an LSP wait no longer makes the package unload leak
  and pin itself (**PR #45**).
- The option chooser measures its text instead of assuming a height — a long
  prompt was drawn behind the first radio button.

### Upgrading

Run `install.cmd` and restart RAD Studio, or load the attached `.bpl`. A running
Claude Code session picks up the new bridge by itself from 1.33.0 on; an older
one needs a new session.

Thanks to **nLeonardt95** for issues #44, #46, #47 and #48, and to
**Ian Branch** for PR #45.

---

## 1.23.2 — 2026-10-05

[Full notes](https://github.com/jaenicke/DelphiRefactoringLight/releases/tag/1.23.2)
— covers 1.11.3 … 1.23.2: 64 versions in 98 commits, and the DUnitX suite grew
from 176 to 351 tests on Win32 and Win64.

- **New feature "Edit methods"**: edit what a class declares — move members to
  another class (also in another unit), change the signature, set modifiers, for
  several members at once. The occurrences are verified with DelphiLSP *before*
  the edit, and afterwards a window lists what still needs hand work.
- **Every refactoring is reachable through the MCP bridge**, and every writing
  tool shows the change before it writes it.
- **An external code audit by Ian Branch** — 12 pull requests plus 7 area issues
  with 123 findings — implemented in full, including several findings where code
  could be lost or silently changed.
- **Find references and rename** work on a cold DelphiLSP session and on large
  projects without dropping occurrences.
- **The plugin reports its own failures**: the status window explains the LSP
  state in plain language and in colour, the main-thread rule is counted, and a
  tool answer that cannot be right is flagged as a defect.
- The interface GUID check fixes what it finds; a result row follows its line
  through your own edits; uses cleanup asks the form designer what it cannot see
  in the source.

---

## 1.11.2 — 2026-09-22

[Full notes](https://github.com/jaenicke/DelphiRefactoringLight/releases/tag/1.11.2)
— a small release with one important fix: **if you use the 64-bit IDE, please
update.**

- The 64-bit IDE could **freeze for about a minute and use 14 GB of memory**
  (#16, thanks @ijbranch). The identifier index cache was written with 8-byte
  numbers by the 64-bit build while the reader expects 4, so four bytes of a unit
  name were read as a count — and on Win64 that multi-gigabyte allocation
  *succeeds*, so the safety net never ran. Both IDEs now write identical cache
  files, every length is checked before memory is reserved, and loading is much
  faster (60 ms instead of 4 s for the complete RTL/VCL).
- **MCP bridge**: less context in every Claude Code session, the bridge carries
  the plugin's version, and the README explains `--scope user` vs `--scope local`.

---

## 1.11.0 — 2026-09-21

[Full notes](https://github.com/jaenicke/DelphiRefactoringLight/releases/tag/1.11.0)
— mostly about **find references and rename being right the first time**.

- **An aborted request no longer deletes a result** (#13, thanks @nLeonardt95):
  while a big project loads, DelphiLSP cancels requests after 10 s, and those
  cancellations were treated as "not a reference".
- Occurrences DelphiLSP does not answer for are **resolved from the sources**
  (qualifier → declared type → member), which also covers the private/public
  overload pair DelphiLSP stays silent about since Delphi 13.1 (RSS-5463).
- **Overloads are told apart** by argument count and, where the text shows them,
  argument types.
- A second, lightweight DelphiLSP session in "agent" mode does the verification
  (14.3 s → 6.5 s for 21 candidates, identical answers).
- **Closing the result window stops the search.**
- **No stack overflow on deep uses graphs** (#15, thanks @ijbranch).
- The 64-bit IDE's **MCP named pipe** works (Windows error 998, a misaligned
  buffer), and a broken registry value can no longer stop the plugin from loading.

---

## 1.7.0 — 2026-09-19 — first official release

[Full notes](https://github.com/jaenicke/DelphiRefactoringLight/releases/tag/1.7.0)
— a refactoring and navigation plugin for the Delphi IDE (RAD Studio 13, 32-bit
and 64-bit), built on DelphiLSP: wherever it matters, every occurrence is
verified by the language server instead of being matched as text.

- **Refactorings**: rename (project, unit, method or selected units, form files
  included), change signature across the whole method family, safe delete,
  extract method, extract variable, wrap in try..finally, convert properties,
  remove with, move to (new) unit, extract/extend interface, add IInterface
  support, align method signature, semantic replace, expand include files.
- **Navigation**: find references with the kind of each occurrence, find
  implementations, find unit references, find original symbol, find the unit for
  an identifier.
- **Code assistance**: live quick fixes (missing unit, "did you mean", broken
  uses entry, missing variable, interface methods, empty implementations, unused
  variables and private members, missing semicolon), code completion with
  generated event handlers and anonymous methods, and uses cleanup.
