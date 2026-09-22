# Nett

Your money, made clear.

Nett is a privacy-focused personal finance ledger and statement importer for iOS.

> **Project status:** Early-stage / pre-release.

## Why Nett?

People who use multiple bank accounts and credit cards often have financial information spread across different statements, apps, and formats.

Nett is being developed to make it easier to import, organise, and review that information without requiring mandatory direct bank-account connections.

## Goals

Nett aims to provide:

- bank and credit-card statement importing;
- transaction normalisation across different statement formats;
- multi-account spending tracking;
- transparent transaction review and categorisation;
- local handling of sensitive financial data wherever practical.

## Privacy

Financial information is sensitive.

Do not commit:

- real bank or credit-card statements;
- account numbers or card numbers;
- personal transaction histories;
- API keys, tokens, certificates, or credentials;
- production secrets or signing material.

Test fixtures must use synthetic or thoroughly anonymised data.

## Current status

Nett is under active development. The current source includes:

- SwiftUI screens for home, transactions, accounts, and settings;
- SwiftData models for accounts, transactions, categories, and merchant-category rules;
- account creation, editing, archiving, and deletion;
- CSV analysis, column mapping, candidate review, duplicate checks, and confirmed import;
- PDF text extraction using PDFKit with on-device Vision OCR fallback;
- a statement-parser architecture with a conservative generic fallback and American Express-specific parsing work;
- local account-detail extraction proposals that require review before any Account changes;
- a credit-card payment simulator using Decimal-based calculations.

There are no direct bank-account connections, cloud features, or external statement-processing services in the current source. PDF import review and broader statement-parser coverage remain in development.

## Building

The project has no third-party package dependencies.

Requirements:

- Xcode with the iOS 27.0 SDK;
- an iOS simulator or device supported by that Xcode installation.

To build and run:

1. Open [PersonalLedger_back.xcodeproj](PersonalLedger_back.xcodeproj) in Xcode.
2. Select the **PersonalLedger_back** scheme and an iOS simulator or device.
3. Choose **Product → Build** (Command-B), then **Product → Run** (Command-R).

The app target’s iOS deployment target is 27.0.

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT License. See [LICENSE](LICENSE).
