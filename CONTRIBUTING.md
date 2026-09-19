# Contributing to PersonalLedger

Thanks for your interest in contributing.

PersonalLedger is currently an early-stage project, so small and focused contributions are preferred.

## Privacy requirements

Never commit:

- real bank or credit-card statements;
- account or card numbers;
- real transaction histories;
- authentication credentials;
- API keys or production secrets;
- signing certificates;
- provisioning profiles.

Test data must be synthetic or thoroughly anonymised.

## Suggested workflow

1. Fork the repository.
2. Create a focused branch.
3. Keep commits clear and reasonably small.
4. Add or update tests where practical.
5. Open a pull request explaining:
   - what changed;
   - why it is useful;
   - how it was tested;
   - whether it affects statement parsing or sensitive financial data.

## Statement/parser contributions

When adding or changing statement parsing:

- use synthetic fixtures;
- document expected fields;
- avoid hard-coded personal identifiers;
- handle malformed input explicitly;
- prefer deterministic parsing where practical;
- add tests where possible.

## Issues

Bug reports and feature requests are welcome.

Do not paste real financial statements or sensitive personal information into public GitHub issues.
