---
name: earned-it-cloudkit-lifecycle
description: Diagnose or change Earned It CloudKit family deletion, clean restart, membership recovery, or one-time invitation issuance and acceptance. Use for these CloudKit lifecycle boundaries, not ordinary chore or allowance work.
---

# Earned It CloudKit lifecycle

Start with the current default branch and the authoritative implementation and docs. Treat preserved worktrees and incident reports as evidence to audit, not changes to combine wholesale.

## Evidence before mutation

- Separate local journal state, private membership-lock state, owner-zone state, public lifecycle authority, share participant state, and presentation state. An error after an await does not prove that earlier CloudKit side effects failed.
- Stage evidence at the boundary that first failed. Preserve typed CloudKit codes, retry timing, states, counts, and equality results. Do not collect raw identifiers or payloads.
- Simulator transports prove application decisions only. Signed, two-account Production behavior requires separately authorized device evidence.
- Read [production boundaries](references/production-boundaries.md) when work touches schema, lifecycle identity, diagnostics, deletion, or either invitation format.

## Safety and authority

- Never infer permission to reset, delete, recreate, or repair live CloudKit data. A diagnostic reset or nuke path is not a product recovery design and must not ship without explicit product authorization.
- Never deploy or mutate CloudKit schema from agent work. Compare the repository contract with the human-managed environment and report any mismatch.
- Preserve exact household, membership-lock attempt, participant, invitation, member, role, and account-generation bindings. Missing, malformed, ambiguous, or foreign authority fails closed.
- Account-wide reset must query lifecycle creator metadata using both the resolved current-user record ID and the exact current-user sentinel, then apply the same sentinel-shape and owner-binding validation before discovery and deletion.

## Invitation review

- Review issuance as a non-atomic workflow. If participant creation or fact upload may already have succeeded, inspect or recover the exact existing participant before creating another one.
- Trace both recipient inputs: the custom package with clear code plus Apple URL, and a raw recovered Apple URL with no clear code.
- A raw URL can select an invitation only through one read of the accepted current-user share participant. Require the exact participant ID, accepted status, private-user role, read/write permission, one unique matching journal invitation, authoritative availability, and an atomic one-time claim before any membership resume or attachment.
- Capture exact share-access state before raw native acceptance. Reject preexisting accepted access or an active membership lock, and promote a retryable acceptance error only when the persisted attempt began without access and the new exact participant uniquely matches one invitation. Probe a persisted accepting attempt before replaying native acceptance. Retain retryable pending state without replay or cleanup when the result is uncertain.
- Keep the custom package bound by both its code digest and Apple URL digest. At the common claim boundary, require its exact current accepted private read/write participant just like the raw path. Neither format may broaden profiles, cross households, revive revoked or expired access, or permit replay.
- Apply that exact participant check again after awaited claim and lock work, immediately before cleanup, retry, resume, or startup recovery synchronously attaches its profile. When pending state names an invitation, the committed membership must name that same invitation.
- Recover an existing unclaimed invitation only after authoritative CloudKit time confirms availability. A device clock may affect display text but must not hide recovery or authorize delivery.
- Show existing-invitation recovery only at the owner-controlled location that can recover the Apple participant, and only when the row retains a participant ID and valid URL digest.
- Recovered invitation presentation retains the original expiration. Never describe recovery as starting a fresh 24-hour lifetime.
- Cancel a queued delayed sync at the exclusive invitation issuance or recovery boundary. If it owned pending facts that remain afterward, schedule their retry when the exclusive operation exits.

## Verification

Use behavior-level tests around the changed boundary. Cover terminal refusal and retryable interruption, not only the happy path. For UI changes, verify distinct 44-point controls, Dynamic Type, accessibility labels, and the actual tap result. Keep parent deletion and invitation behavior protected when changing recipient handling.
