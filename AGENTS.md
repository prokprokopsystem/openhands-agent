# OpenHands Agent — instructions for Codex

These instructions apply to the whole repository.

## Working principle

- The repository is the source of truth. Do not rely on chat history when repository state disagrees with it.
- Keep independent engineering judgment. Do **not** assume that a task description, previous ChatGPT recommendation, previous Codex decision, or existing implementation is correct.
- If you find a contradiction, unsafe assumption, architectural error, or a materially better solution, say so and explain the evidence. Do not blindly implement a known-bad instruction.
- Limit **actions**, not **thinking**: investigate as broadly as needed for correctness, security, dependencies, and regression risk.

## Context economy

Start with the smallest useful context:

1. `docs/Состояние.md`.
2. The current stage document referenced there.
3. The latest relevant commit and diff.
4. Files directly involved in the task.

Do not re-read the whole repository by default. Expand the review when necessary to verify an assumption, dependency, security boundary, integration, or regression risk. For an explicit audit/review task, read as broadly as the audit requires.

## Change discipline

- Continue from the state recorded in the repository; do not redesign accepted architecture without evidence that it is wrong or unsafe.
- Prefer the smallest correct change over broad refactoring.
- Do not fix unrelated issues unless they block the current task. Report them separately.
- Do not touch production, servers, networking, firewall, SSH, secrets, storage, `main`, or destructive operations unless the user explicitly asks for that exact action.
- Never expose secrets in chat, logs, diffs, commits, or test output.
- Reuse existing components, wrappers, tests, scripts, and decisions instead of creating duplicates.

## Verification

- Before changing code, understand the relevant current behavior.
- After changing code, run the narrowest relevant tests first, then any broader checks needed for confidence.
- Treat passing tests as evidence, not proof; verify security and behavior assumptions independently when relevant.
- Do not claim completion when verification is incomplete.

## Project continuity

For completed implementation work:

- Update `docs/Состояние.md` briefly with what changed, verification performed, commit SHA, and the next logical step.
- Keep documentation consistent with actual repository state.
- Make focused commits with clear messages.

For read-only review/audit tasks, do not modify documentation unless explicitly requested.

## Project skill

Use the repository skill `openhands-project-work` for substantive work in this project:

- `.agents/skills/openhands-project-work/SKILL.md`

The skill contains the detailed workflow. This `AGENTS.md` stays intentionally short so permanent context remains cheap.