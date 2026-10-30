---
name: evidence-first-meeting-notes
description: Produces exactly four clear meeting notes and only genuinely verified action items, with every action item supported by a contiguous long-form quotation from the source.
version: 1.0.0
---

# Evidence-First Meeting Notes

## Purpose

Use this skill whenever the user provides a meeting transcript, recording transcript, notes, chat log, or minutes and asks for:

- exactly four quick notes that let a non-attendee understand what happened;
- detailed action items written as a headline and description; and
- proof that every action item is real, rather than an AI-generated assumption, suggestion, or “smoke and mirrors” task.

The governing principle is:

> **No clear commitment, assignment, or agreed next step in the source means no confirmed action item.**

It is acceptable to return zero confirmed action items. It is never acceptable to invent one merely because an action-item section is expected.

---

## Source-of-Truth Rule

Treat the supplied meeting source as the sole source of truth unless the user explicitly requests outside research or additional context.

1. Read the full source before summarizing. Do not rely only on isolated search snippets.
2. Preserve the meeting’s terminology, names, products, customer concerns, decisions, and uncertainty.
3. Do not silently fill gaps with general knowledge, business logic, or assumptions about what the team “must” do next.
4. Do not turn a product capability, example, aspiration, opinion, concern, or hypothetical scenario into an action item.
5. Do not claim agreement, approval, ownership, or a deadline unless the source supports it.
6. When speaker labels are missing or unreliable, say that the owner is not identifiable from the transcript. Never infer the speaker from organizational context.
7. When the transcript is unclear, narrow the statement to what is certain instead of making it sound more complete.

---

## Required Output Structure

Always use this order:

1. **Meeting Summary — 4 Quick Notes**
2. **Verified Action Items**
3. **Conditional or Proposed Follow-Ups** — include only when relevant and clearly label these as not active action items
4. **Action-Item Audit: Excluded Candidates** — include when the meeting contains tempting but unsupported action-like language

Do not bury action items inside the four notes.

---

# Part 1 — Meeting Summary: Exactly 4 Quick Notes

## Objective

The four notes must be concise enough to scan, but complete enough that someone who missed the meeting can accurately explain:

- why the meeting happened;
- what the important business or technical problem was;
- what was presented, discussed, challenged, decided, or clarified; and
- how the meeting ended and what happens next.

## Mandatory Format

Use exactly four numbered notes. Each note must have:

### `1. Headline`

**Description:** Two to four complete sentences explaining the substance and significance.

## Coverage Model

Unless the meeting structure strongly requires a different arrangement, cover these four functions:

1. **Purpose and context** — who or what the meeting was about and why the parties were speaking.
2. **Important needs, problems, or requirements** — the customer or team’s actual concerns, not generic background.
3. **Material discussion, demonstration, decision, or disagreement** — what the meeting spent meaningful time resolving or testing.
4. **Outcome and next step** — where the discussion landed, including unresolved questions and verified follow-up.

## Rules for the Four Notes

- Exactly four notes. Never provide three, five, or a hidden fifth note in a conclusion.
- Each headline must communicate substance. Avoid headings such as “Discussion,” “Overview,” or “Next Steps.”
- Write for a person who did not attend. Do not use unexplained shorthand or vague references such as “this,” “that issue,” or “the system.”
- Distinguish what the presenter claimed from what the customer confirmed.
- Capture objections, skepticism, risks, and unresolved concerns when they materially shaped the meeting.
- Do not make the summary sound more positive, decisive, or final than the meeting actually was.
- Do not repeat the same point across multiple notes.
- Do not clutter the four notes with long quotations. Save quotation evidence for the action-item section unless the user specifically requests evidence for every note.
- Use source citations, line ranges, page numbers, or timestamps when available.

---

# Part 2 — Verified Action Items

## The Evidence Gate

A candidate may appear under **Verified Action Items** only when the source supports a real future task. Run every candidate through all five tests below.

### Test 1: Future Work

The statement must require something to happen after the meeting.

Pass examples:

- “I will send the revised file tomorrow.”
- “Patrick, please update the ticket.”
- “Once the recording is available, we will send it to Franco.”

Fail examples:

- “We already deployed it.”
- “The engineers are currently working on it,” unless a new deliverable or commitment is added.
- “The system can create a dashboard.”

### Test 2: Concrete Deliverable or Event

The future work must be specific enough to describe as an observable result.

Pass examples:

- send the meeting recording;
- provide the Canadian proposal templates;
- update the Jira ticket with test evidence;
- schedule a follow-up call after questions are collected.

Fail examples:

- “look into it” with no defined issue or outcome;
- “keep this in mind”;
- “support the customer”;
- “make it better.”

When the transcript uses vague language but the object is clear from the immediately surrounding context, describe only that supported object. Do not expand the scope.

### Test 3: Commitment, Assignment, Request, or Agreement

At least one of the following must be present:

- a speaker explicitly commits: “I will…,” “I’ll…,” “we will…”;
- a speaker directly assigns or requests: “Please send…,” “Patrick will…,” “Why don’t you send…”;
- the group explicitly agrees to a proposed next step: “Let’s do that,” followed by “Okay,” “Agreed,” “Yes,” or equivalent acceptance;
- the task is stated as a firm requirement and ownership is clearly established.

The following language alone is not enough:

- “could,” “might,” “maybe,” “possibly,” “it would be good,” “we should consider”;
- “I can be available”;
- “we need to” without an assignment, commitment, or agreed next step;
- “let’s” when nobody accepts and the surrounding discussion remains speculative;
- an idea offered during brainstorming;
- a salesperson describing what a future implementation could do.

### Test 4: Attribution Integrity

Every owner, recipient, approver, dependency, and deadline in the written action item must be supported by the source.

- Name the owner only when explicitly named or unambiguously identifiable.
- If the task is definite but the owner is not identifiable, write: **Owner: Not identifiable from the transcript.**
- If one owner is named but another is not, identify only the named person and state that the co-owner is not identified.
- Never assign an action to the person who seems most logical.
- Never convert the speaker into the owner unless speaker attribution is available.

### Test 5: Scope Match

The action description must not contain any material detail that the quotation fails to support.

Before finalizing, compare the action item to its quote word by word:

- If the action says “prepare and send,” the evidence must support both preparation and sending.
- If the action says “send the minutes and recording to Franco,” the evidence must support both items and the recipient. If it supports only the recording, narrow the action to the recording.
- If the action says “by Friday,” the source must explicitly state Friday.
- If the action says “for approval,” the source must explicitly identify approval as the purpose.
- If the action says “all attendees,” the source must indicate that audience.

If a detail cannot be proven, delete it, label it unknown, or move the candidate out of the confirmed section.

---

## Action-Item Certainty Classes

### A. Confirmed Action Item

Place in the main action-item section only when the Evidence Gate is passed.

Typical evidence:

- direct commitment;
- direct assignment;
- accepted request;
- explicitly agreed deliverable.

### B. Conditional Follow-Up — Not Yet Active

Use a separate section when the task activates only if a stated condition occurs.

Examples:

- “If Craig has more questions, let’s schedule another call.”
- “If the test fails, we will roll back.”

Do not present these as currently due. State the trigger exactly.

### C. Proposed or Discussed Next Step — Not Confirmed

Use only when it is useful to preserve an important proposal, but no commitment or acceptance exists.

Examples:

- “Maybe we can connect locally.”
- “We should consider a pilot.”

These are not action items.

### D. Excluded Candidate

Exclude ideas, availability statements, examples, hypotheticals, existing work, background facts, and implied responsibilities.

When several tempting candidates exist, show a short audit explaining why they were excluded. This lets the user verify that the model deliberately rejected “fake action items.”

---

## Required Format for Every Confirmed Action Item

### `1. Action Headline — Verb + Specific Deliverable`

**Description:** Explain precisely what must be produced, sent, changed, scheduled, reviewed, or decided. Include the stated recipient, dependency, or purpose only when supported.

**Owner:** Exact named owner, or “Not identifiable from the transcript.”

**Recipient / Stakeholder:** State only when explicit. Otherwise write “Not stated.”

**Due Date:** Exact deadline if stated. Otherwise write “Not stated.”

**Trigger / Dependency:** State any explicit prerequisite, such as “after the recording is received.” Otherwise write “None stated.”

**Action Certainty:** Confirmed.

**Owner Certainty:** High, Medium, or Unknown, with a brief reason.

**Long-Form Verification Quote:**

> Quote a contiguous passage containing enough context to prove the request or commitment, the deliverable, and any acceptance. Include the original wording verbatim.

**Source:** Include timestamp range and, when available, line or page range.

**Why This Qualifies:** Explain exactly which language creates the obligation or agreed next step.

**Do Not Overstate:** Identify any tempting unsupported detail that was intentionally omitted, such as an unstated owner or calendar deadline.

---

# Long-Form Quote Verification Protocol

The quote is not decoration. It is the evidence record.

## Quote Length and Context

- Use a contiguous passage, normally two to eight sentences or enough dialogue turns to show the request and response.
- Include the lead-in when it changes meaning.
- Include the acceptance or commitment when it occurs immediately after the request.
- Include the conditional phrase when the action depends on a condition.
- Prefer a slightly longer quote over a short fragment that can be misread.

## Quote Integrity

- Quote verbatim from the source.
- Do not rewrite grammar inside the quote.
- Do not combine non-contiguous sentences into one quotation.
- Do not use ellipses to remove words that weaken, qualify, or condition the action.
- If two separate passages are necessary, use two clearly labeled quote blocks with separate source references.
- Never use a product description or hypothetical example as proof of an operational commitment.

## Quote-to-Action Cross-Check

After drafting each action item, verify all of the following:

1. The action verb is supported.
2. The deliverable is supported.
3. The owner is supported or marked unknown.
4. The recipient is supported or marked not stated.
5. The deadline is supported or marked not stated.
6. The trigger or dependency is supported.
7. The action is future-oriented.
8. The passage shows commitment, assignment, or agreement.
9. No extra scope was added for completeness.
10. The quote is long enough that another reviewer would reach the same conclusion.

If any check fails, revise, downgrade, or exclude the action item.

---

# Anti-Hallucination and “Smoke and Mirrors” Rules

Never turn any of the following into a confirmed action item unless a separate explicit commitment is present:

1. **Product capabilities:** “The platform can create dashboards.”
2. **Demo narration:** “It proposes a rebin and files it for approval.”
3. **Hypothetical scenarios:** “If a line goes down, it could notify someone.”
4. **General needs:** “We need better predictability.”
5. **Customer pain points:** “Yield problems can last nine months.”
6. **Existing work:** “Engineers are working on the process issue.”
7. **Availability:** “I can be available for a meeting.”
8. **Tentative language:** “Maybe I can connect with you.”
9. **Unaccepted recommendations:** “We should run a pilot.”
10. **Implied follow-up:** A salesperson gave a demo, therefore the team must send a proposal.
11. **Normal business assumptions:** A meeting happened, therefore someone must create minutes.
12. **Role-based assumptions:** The account manager usually sends follow-ups, therefore the account manager owns this task.
13. **Desired outcomes:** “Improve uptime,” “solve yield,” or “increase confidence” without a defined assigned deliverable.
14. **Questions:** “Can you share the data?” unless the response creates an accepted obligation.
15. **Polite acknowledgements:** “Sounds good” when it refers generally to the discussion rather than a specific task.

---

# Decision and Discussion Accuracy Rules

Meeting notes often become misleading when the model turns discussion into decisions. Apply these rules:

- A **decision** requires explicit selection, approval, rejection, or agreement.
- A **recommendation** is not a decision.
- A **customer concern** is not a requirement unless the customer states it as one.
- A **presenter claim** is not a customer validation.
- A **question** is not an objection unless the speaker expresses doubt, disagreement, risk, or a competing view.
- An **unresolved topic** must remain unresolved in the summary.
- When two participants frame the issue differently, preserve both views.
- If the meeting ends because of time rather than resolution, state that.

---

# Internal Analysis Workflow

Use this workflow before writing the final output.

## Step 1: Build a Meeting Map

Identify:

- meeting purpose;
- participants or named stakeholders;
- products/projects discussed;
- customer problems and desired outcomes;
- demonstrations or proposed solutions;
- objections and unresolved questions;
- decisions;
- explicit next steps.

## Step 2: Build an Evidence Ledger

Create an internal list of every statement that sounds action-like. For each candidate record:

- exact quote;
- timestamp/line range;
- proposed owner;
- deliverable;
- commitment language;
- condition;
- deadline;
- classification: confirmed, conditional, proposed, or excluded.

## Step 3: Run the Evidence Gate

Reject or downgrade every candidate that fails even one material test.

## Step 4: Draft the Four Notes

Select only the four most important story elements. Make sure the customer’s actual concern and the meeting outcome are represented.

## Step 5: Draft Verified Action Items

Use the required detailed format. Do not merge separate tasks merely to reduce the count.

## Step 6: Verify Quotations Against the Source

Re-read the exact source range. Confirm that the quotation is verbatim and that the description does not exceed it.

## Step 7: Perform the Final Skeptic Review

Ask:

- Could a skeptical attendee point to the transcript and prove this action item?
- Did I name anyone who was not explicitly assigned?
- Did I invent a deadline, recipient, purpose, or expected outcome?
- Did I mistake a product demo for a team commitment?
- Did I hide a condition such as “if,” “maybe,” or “once”?
- Did I make the meeting sound more resolved than it was?

If the answer to any risk question is yes, fix it before responding.

---

# Output Template

```markdown
# Meeting Summary

## 4 Quick Notes

### 1. [Specific headline]
**Description:** [Two to four sentences explaining what happened and why it mattered.]

### 2. [Specific headline]
**Description:** [Two to four sentences.]

### 3. [Specific headline]
**Description:** [Two to four sentences.]

### 4. [Specific headline]
**Description:** [Two to four sentences, including the outcome and next step.]

## Verified Action Items

### 1. [Verb + specific deliverable]
**Description:** [Exact future work supported by the source.]

**Owner:** [Name or Not identifiable from the transcript]

**Recipient / Stakeholder:** [Exact recipient or Not stated]

**Due Date:** [Exact date or Not stated]

**Trigger / Dependency:** [Exact condition or None stated]

**Action Certainty:** Confirmed

**Owner Certainty:** [High / Medium / Unknown — reason]

**Long-Form Verification Quote:**
> [Contiguous verbatim passage]

**Source:** [Timestamp and line/page range]

**Why This Qualifies:** [Direct explanation of commitment or assignment language.]

**Do Not Overstate:** [Unsupported details intentionally omitted.]

## Conditional Follow-Ups — Not Active Action Items

### 1. [Conditional task]
**Trigger:** [Condition]
**Evidence:** [Quote and source]
**Why It Is Not Active Yet:** [Reason]

## Action-Item Audit: Excluded Candidates

- **[Candidate statement]:** Excluded because [specific evidence rule].
```

---

# Final Quality Standard

A successful response should allow the user to say:

- “Someone who missed the meeting can understand the entire story from four notes.”
- “Every confirmed action item has a real task, not an implication.”
- “I can see the exact long-form quotation that proves each task.”
- “Unknown owners and deadlines are honestly labeled instead of guessed.”
- “Conditional ideas and vague follow-ups are not disguised as commitments.”
- “The model showed me which tempting fake action items it rejected.”

When evidence is weak, be conservative. **Precision is more important than producing a longer action-item list.**
