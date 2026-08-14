# Project rules (promoted, human-readable)

- adoption: team
- branch-model: staged
- graphify: deferred at onboard - no code to index yet; the first /graphify-wrapper-query builds it, or run /graphify-wrapper-setup once the stack lands
- stack: greenfield at onboard 2026-08-12 - PRD only (meetings-prd.md), no code; planned SwiftUI macOS 26 app + CLI in one Swift package (see PRD D1/D4)
- guardrails: deferred at onboard - no stack yet; secret-scan pre-commit hook installed and proven (clean pass / planted key refused / revert pass). Re-run /guardrails-install once /groundwork lands the Swift package, which is when verify/dev-run/seed-reset/ops-runner, the real denylist and the enforcement hook can be recorded from what exists
- safety-secret-leak: a committed secret is compromised - revoke and reissue the key first, then purge history; deleting the line is not enough.
- pending-decision: merge-policy - may the agent merge a gates-passed green PR, or does a human click it? (parked at onboard, no stack yet)
- pending-decision: release-cadence - does a merge continue into a release, or wait to be asked? (parked at onboard, no stack yet)
