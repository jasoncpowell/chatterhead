# Agent Prompts

This document captures the prompts used with Claude Code to research, plan, and
build this chat application. It is organized into three phases: **Initial
Research**, **Implementation Plan**, and **Executing the Plan**.

---

## Initial Research

> _Select Opus model._

I am building a simple chat application for a take home coding interview. I would
like you to analyze the attached PDF, and create a new `/docs` folder with a new
markdown file. In that MD file, I would like you to consider different
possibilities for how this simple chat application could be implemented according
to the provided PDF and the requirements and guidelines it contains. I want to
use the best practices for modern Elixir, Phoenix, LiveView applications and take
advantage of OTP design patterns and built-in libraries and functionality as an
experienced senior developer would. This document is not intended to be a full
implementation plan, but will be used as a starting point for the implementation
plan that I generate afterwards. As you go, ask any questions you have. 1-3
different plans is adequate. If there is only one best way to accomplish this, it
is acceptable to only include one plan overview.

> _Switch model to Sonnet._

Review `docs/01-architecture-options.md` and look for errors, potential gotchas
that would surface during implementation plan creation, inconsistencies with
published documentation, and opportunities for improvement. Remember that this is
not an implementation plan, so keeping the analysis higher level is acceptable.

> _Return to original session._

Made some changes to the doc based on feedback I received. Can you verify them and
ensure that all the suggestions and updates are correct? _(Copied summary of
updates into prompt.)_

---

## Implementation Plan

> _Select Opus model with advanced thinking._

I finished creating `docs/01-architecture-options.md` to research different
approaches for creating this chat app. Now I would like to create a detailed
implementation plan that can be directly used by Claude Code to generate the code.
I would like to use Plan B as proposed in the document.

**Breaking the work up into separate tasks**

In the implementation plan, separate the creation of this chat app into
self-contained, individually-testable tasks as though you were creating tickets
for a Jira board. Each task should have a summary of the work to be done, a list
of commits, and a notes section containing all necessary background information,
open questions to be decided by a developer, and a list of acceptance criteria
which clearly define the expected behaviors of the app once the work has been
completed.

**Atomic Commit style**

Utilize atomic commits when creating a list of commits for each task. Each commit
should be a focused, self-contained unit of work. Unit tests should be included
with the commit that introduces the logic being tested, and not in a separate
commit.

The suggested ~2 hour time window is not relevant to this implementation plan. The
approach taken should be the most performant, most idiomatic, fully tested, and
most readable one regardless of the estimated time to implement.

As you design the plan, stop and ask any clarifying questions you may have along
the way where requirements or implementation details are unclear. I have attached
the PDF containing the requirements for this exercise as an additional reference.

> _Switch model to Sonnet._

I created an implementation plan for this app in `docs/02-implementation-plan.md`.
Review the plan completely and look for errors, potential gotchas that would
surface during implementation, inconsistencies with published documentation, and
opportunities for improvement. Remember that this is intended to be implemented by
an LLM, so it should be obvious to the model what needs to be done.

> _(Feedback was generated.)_

> _Switch back to previous session._

I got some feedback on the implementation plan. Can you verify that it is all
valid feedback? _(Copy feedback from review.)_

> _(All feedback was valid, and a few extra points were added.)_

Apply these changes to the plan.

---

## Executing the Plan

I am now ready to begin executing the implementation plan found in
`docs/02-implementation-plan.md`.

* Proceed one task at a time.
* Before each task, prompt me to create a new branch with a suggested name.
* After the branch is created, begin implementing the work commit by commit.
* After each commit is done, prompt me to manually add the changes and provide a
  suggested commit message.
* Once confirming that the commit is finished, proceed to the next commit.
* Once a task is completed, update the implementation plan to note that the task
  was completed.
