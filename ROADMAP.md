# PersonalLedger Roadmap

PersonalLedger is an early-stage open-source iOS project.

This roadmap describes intended work and is not a release commitment.

## Phase 1 — Public foundation

- [x] Publish initial iOS source after privacy and secrets audit
- [ ] Document project architecture
- [x] Add repeatable local build instructions
- [x] Add synthetic statement fixtures
- [x] Add parser and transaction-normalisation tests
- [ ] Create first tagged pre-release

## Phase 2 — Statement import

- [x] Define a common transaction model
- [ ] Support multiple statement formats
- [x] Add import validation and user review for CSV imports
- [x] Detect likely duplicate transactions
- [ ] Improve error handling for unsupported layouts

## Phase 3 — Ledger experience

- [x] Multi-account ledger views
- [ ] Search and filtering
- [x] Transaction categorisation
- [x] Spending summaries
- [ ] Export of user-owned ledger data

## Phase 4 — Reliability and privacy

- [ ] Expand automated test coverage
- [ ] Add privacy-focused threat modelling
- [ ] Document local data-storage behaviour
- [ ] Review optional AI-assisted parsing behind a clearly separated interface
- [ ] Add contributor documentation for parser adapters
