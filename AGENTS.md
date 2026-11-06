# AGENTS.md

Instructions for OpenAI coding agents working in this repository.

## GitHub delivery

Apply this section whenever a task touches GitHub repositories, branches, commits,
pull requests, CI, releases, or deployment. Otherwise ignore it.

### Authority

Assume connected GitHub repositories are available for normal read/write work.
Inspect actual state before reporting an access limitation.

Proceed without additional confirmation for reversible repository actions,
including creating branches, editing files, committing and pushing, opening or
updating pull requests, commenting or reviewing, marking a pull request ready,
and merging when all merge conditions below are satisfied.

Always obtain explicit user authorization before deployment or release
activation, repository deletion or transfer, destructive data operations, or
irreversible actions outside the repository.

A merge is not a deploy. Deployment authorization is never implied by merge
authorization and is single-use unless the user explicitly says otherwise.

### Repository rules

- Never commit directly to the default branch.
- Start each task from the latest default branch unless an existing task branch
  is explicitly being continued.
- Use one branch and one pull request per independently reviewable task.
- Prefer the smallest complete change.
- Do not mix unrelated features, fixes, refactors, or cleanup.
- Do not repeat work already present in another branch or pull request.
- Repository-specific domain, build, test, and safety rules remain authoritative.
  If an older generic Git workflow conflicts with this section, this section
  wins unless the repository explicitly declares a current exception.

### Agent identity and attribution

Applies to every coding agent and tool — Claude Code, ChatGPT Codex, Grok,
Copilot, Cursor or any other system — whenever it writes to GitHub on behalf
of a person.

Roles:

- **Human owner** — the person who asked for the change and is accountable
  for it.
- **Owner's bot** — the human owner's dedicated Git/GitHub bot identity,
  configured in the execution environment. It authors agent commits.
- **Tool** — the agent product actually doing the work, named as the product
  calls itself (`Claude Code`, `ChatGPT Codex`, `Grok`, ...).

| Action       | Comes from                               | Signature                          |
|--------------|------------------------------------------|------------------------------------|
| Commit       | author and committer: owner's bot        | `Assisted-by: <Tool>` trailer      |
| Pull request | human owner's credentials                | description names tool and bot     |
| Review       | the reviewing tool                       | `Review by <Tool>` header          |
| Merge        | human owner's credentials, preferably    | trailers from commits preserved    |

#### Commits

- Author and committer are the owner's bot identity configured for the
  environment. Never use the human owner's name or email, and never a tool
  vendor's noreply address, as the commit author.
- Every agent commit ends with `Assisted-by: <Tool>` naming the tool that
  actually ran, one line per tool. The model may follow in parentheses, e.g.
  `Assisted-by: Claude Code (Claude Opus 5.5)` or
  `Assisted-by: ChatGPT Codex`.
- `Co-authored-by` is only for real people or accounts that materially wrote
  part of the change. A vendor trailer that the tool's harness requires may
  stay, but it never replaces `Assisted-by`.
- If no bot identity is configured, stop and ask. Do not fall back to the
  human owner's identity.

#### Pull requests

- Try to open the pull request with the human owner's credentials — the
  GitHub connection the person gave the tool.
- The description says the change was prepared with `<Tool>` and that the
  commits are authored by the owner's bot. Never present agent work as typed
  by the person.
- If only bot credentials are available, open it from the bot and name the
  human owner in the description.

#### Reviews

- Reviews and review comments are signed by the reviewing tool: the first
  line reads `**Review by <Tool>**`. A tool reviewing another tool's work
  names both.
- Post the review as a comment review. Do not approve with the human owner's
  credentials: GitHub does not count an approval of your own pull request,
  and it would present the agent's verdict as the person's approval. Never
  dismiss or circumvent a required review.

#### Merge

- The final merge is preferably made with the credentials of the human who
  created the pull request. When the agent works through that person's
  connection, it merges under the merge rules below. Otherwise it leaves the
  pull request ready and reports that it waits for the human merge.
- A squash or merge commit keeps every `Assisted-by` and `Co-authored-by`
  trailer from the branch commits.

#### Check before the first write

Verify the authenticated GitHub account, the local Git author and committer,
and that both match the roles above. Recheck when credentials or the
environment change. On a mismatch, stop and report it instead of switching
accounts silently.

### Before changing anything

Inspect only the state needed for the current decision:

1. repository and default branch;
2. relevant repository instructions;
3. existing pull requests or branches for the same task;
4. targeted files and contracts;
5. relevant CI and merge requirements.

Reuse state already verified during the current task. Do not repeatedly fetch
or inspect unchanged state.

If a previous pull request is part of the same dependency chain, resolve it
before creating dependent work. Independent work may proceed in parallel when
it cannot conflict.

### Delivery flow

For each task, follow this state machine:

inspect
→ latest base
→ task branch
→ smallest complete implementation
→ draft pull request
→ targeted checks
→ full CI
→ deploy validation when applicable
→ self-review exact diff
→ ready for review
→ merge
→ refresh base

Deployment is a separate protected step after merge.

### Pull requests

Open the pull request as a draft while implementation or verification remains.

Keep it draft while implementation is incomplete, CI is unresolved, a required
decision is outstanding, required verification could not be performed, or a
known blocker remains.

Once the exact head revision is verified, required CI is green, applicable
deploy validation is green, the requested scope is complete, and no known
blocker remains, mark the pull request ready without asking the user again.

Merge automatically when all of the following are true:

- the requested task is complete;
- the final diff matches the intended scope;
- required CI for the exact head is successful;
- deploy validation is successful or not applicable;
- repository merge requirements are satisfied;
- no unresolved blocker invalidates the change.

Use an allowed repository merge method. A merge-method restriction does not
invalidate an otherwise verified head.

After merge, record the resulting state and refresh the default branch before
dependent work.

### Verification

Treat CI as the authoritative correctness gate where CI exists.

Full CI may include formatting, linting, static analysis, tests, contract
validation, and builds required for correctness.

Do not rerun successful CI for an unchanged commit merely because the pull
request was marked ready or merged.

Repeat verification only when relevant inputs changed, the head changed,
relevant environment state changed, the platform requires it, or repository
policy explicitly requires it. When repeating verification, run only affected
checks unless full CI is required.

A failing unrelated automation is not automatically a correctness blocker.
Inspect the failure and determine whether it is relevant to the requested
change or a required repository gate.

Never claim a check passed unless its result was actually observed.

### Deploy validation

Where deployment exists and can be validated before merge, verify deployability
without activating a release.

Deploy validation may check artifacts or packages, deployment configuration,
environment contracts, migrations, preflight, readiness, and pre-activation
smoke contracts.

Reuse CI artifacts and results where possible. Deploy validation must not
unnecessarily repeat correctness CI, rebuild an identical artifact, or activate
the release.

### Deployment

Deployment always requires explicit user authorization, even after an automatic
merge.

After authorization, deploy the already verified revision or artifact, perform
the environment transition, activate the release, and verify minimal
post-deploy health.

Do not silently expand deployment authorization to later deployments.

### Engineering behavior

Inspect before modifying.

Prefer verified state over assumptions, repository contracts over generic
conventions, root-cause fixes over symptom patches, the smallest sufficient
change over broad rewrites, explicit ownership and boundaries over hidden
coupling, predictable behavior over cleverness, and observable failures over
silent fallback.

When a supporting fix is inseparable from the requested task because the
repository could not otherwise validate or merge that task, make the smallest
such fix and explain why it belongs in the same pull request.

Unrelated defects discovered during the task belong in separate follow-up work.

### Tool behavior

Use available GitHub capabilities directly when they can complete the task.
Do not ask the user to perform GitHub actions the available tools can perform.

Prefer batched independent reads and precise writes. Reuse repository
identifiers, branch names, commit SHAs, pull request numbers, and verified
results rather than rediscovering them.

Inspect detailed CI logs only for failed or ambiguous checks. Do not poll state
that cannot yet have changed.

Never report repository state, successful writes, merges, CI results, or
deployment results without evidence from the corresponding operation.

### Reporting

Report outcomes, not tool choreography.

At meaningful milestones or completion, state what changed, why, what was
verified, the current delivery stage, any remaining blocker or material risk,
and whether a protected action such as deployment still requires authorization.

Do not ask for confirmation when this policy already grants authority to
continue. If the task cannot be completed, identify the concrete blocker and
the exact state reached instead of giving a generic access or tooling
disclaimer.
