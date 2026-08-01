---
name: openhands-project-work
description: Work safely and efficiently in the prokprokopsystem/openhands-agent repository while preserving project continuity, independent technical review, minimal context use, focused changes, tests, and concise state documentation.
---

# OpenHands Project Work

Use this skill for substantive implementation, debugging, review, security audit, deployment preparation, or documentation work in this repository.

## Goal

Continue the project from its recorded state without wasting context, silently changing architecture, or blindly trusting previous decisions.

The agent must remain an independent engineer: challenge incorrect assumptions and verify important claims before changing the project.

## 1. Orient from repository state

Read in this order unless the task itself requires a broader audit:

1. `docs/Состояние.md`.
2. The current stage document referenced by `docs/Состояние.md`.
3. The latest relevant commit and its diff.
4. The files and tests directly involved in the requested task.
5. Relevant architectural decisions from `docs/Решения.md` only when they affect the task.

Do not automatically re-read every document or source file.

If the initial context reveals a dependency, contradiction, security boundary, or possible regression elsewhere, expand the investigation as far as necessary.

## 2. Independently validate the task

Before implementing:

- Check whether the requested change matches the actual repository state.
- Check whether an existing component already solves the problem.
- Check whether the proposed solution conflicts with an architectural decision, security boundary, test, or runtime constraint.
- Treat recommendations from ChatGPT, Codex, DeepSeek, Hermes, documentation, and previous commits as hypotheses that may contain mistakes.

If the requested implementation is materially wrong or unsafe:

- do not silently implement it;
- explain the conflict with concrete repository evidence;
- propose the smallest safer/correct alternative.

Independent review is part of the job, not an exception.

## 3. Keep scope focused

For implementation tasks:

- Change only files necessary for the task and its tests/documentation.
- Prefer a minimal patch over unrelated cleanup or refactoring.
- Do not reorganize ports, keys, paths, networks, deployment topology, or accepted architecture for convenience.
- If an unrelated defect is discovered, record it in the final report unless it directly blocks the requested work.

For audit/review tasks:

- Make no changes unless the user explicitly asks for fixes.
- Search broadly enough to test the important assumptions, even if that requires reading more of the repository.

## 4. Safety boundaries

Without an explicit user instruction for the exact action, do not:

- modify production systems;
- run deployment against production;
- change `main`;
- modify SSH, firewall, system users, disks, storage, or secrets;
- delete Docker volumes or significant data;
- run destructive recursive deletion;
- disable audit, backups, or safety checks;
- expose secret values in output, logs, diffs, commits, prompts, or documentation.

When work is intended only for repository preparation, keep it repository-only.

## 5. Work sequence

For a normal coding task:

1. Establish current behavior/state.
2. Identify the smallest correct change.
3. Inspect the tests that should prove the behavior.
4. Implement the patch.
5. Run narrow relevant tests.
6. Run broader checks only where needed for confidence.
7. Inspect the final diff for accidental scope expansion and secret leakage.
8. Update project state documentation if implementation is complete.
9. Commit the focused change.

Do not repeatedly retry the same failed approach without new evidence. After repeated failure, stop and diagnose the root cause before another attempt.

## 6. Verification standard

A task is not complete merely because a command exited successfully.

Verify, as applicable:

- expected behavior;
- negative/denial cases;
- security boundaries;
- rollback or failure behavior;
- configuration consistency;
- regression tests;
- documentation versus implementation.

When security-sensitive code is involved, actively test bypass attempts relevant to the boundary being changed.

## 7. Documentation continuity

`docs/Состояние.md` is the handoff point between sessions.

After completed implementation work, update it concisely with:

- what was changed;
- what was verified and the result;
- the resulting commit SHA when available;
- known unresolved issues;
- one next logical technical step.

Do not turn `Состояние.md` into a verbose session transcript.

If a separate stage document contains detailed checklists, update that document only when its factual status changed.

## 8. Final report

Keep the final report compact. Include:

1. What changed or, for an audit, what was found.
2. Tests/checks run and their results.
3. Files changed, if any.
4. Commit SHA, if a commit was created.
5. The next logical step.
6. Important issues intentionally left unchanged.

Do not dump large logs unless they are needed to explain a failure.

## Core principle

**Save tokens by avoiding redundant context, not by suppressing engineering judgment.**

The agent should be economical in reading and output, but thorough enough to catch mistakes before they enter the project.