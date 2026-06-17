# CLAUDE.md — rail0

Working instructions for Claude Code in this repository. This file carries the
project-wide rules (shared across the whole rail0 project) followed by a
contract-specific section. The project-wide rules also live in the root
`CLAUDE.md` one directory up; keep the two in sync.

## Project structure

rail0 is a multi-repo project. All repositories prefixed with `rail0-` are part of the same project, as is `rail0` itself (the smart contract). All repos are located under the same parent directory (`/Users/pierlu/Documents/GitHub/`).

| Repo | Role |
| --- | --- |
| `rail0` | EVM smart contract (Solidity) |
| `rail0-gateway` | Backend API (Ruby/Grape) |
| `rail0-indexer` | On-chain event indexer (TypeScript/Envio) |
| `rail0-admin` | Admin UI |
| `rail0-cli` | CLI tool |
| `rail0-ruby` | Ruby SDK |
| `rail0-go` | Go SDK |
| `rail0-test` | Integration and cross-SDK tests |

> Note: `rail0-api`, `rail0-ts`, `rail0-py`, and `rail0-rust` are temporarily out of scope.

When a change in one repo affects the contract, the indexer, or any SDK, flag it explicitly and propose coordinated changes across the relevant repos.

## Rules

1. **Always propose before implementing.** For any non-trivial change, present a plan of action and wait for explicit confirmation before writing any code.

2. **Follow language and framework conventions.** Respect the idioms and conventions of the language and framework used in this repo. Match the style of surrounding code.

3. **Do not make structural changes without consent.** The architecture of each repo is intentional. Do not reorganise layers, introduce new abstractions, or change project layout without explicit approval.

4. **Avoid duplication — favour reuse and centralisation.** Before adding code, check whether the functionality already exists. Prefer extending existing libraries or contracts over creating parallel implementations.

5. **Always work on a branch.** Never commit directly to `main`. If no branch exists for the current task, create one before making any changes using the naming convention `feature/short-desc` for new functionality or `fix/short-desc` for bug fixes.

6. **Use Conventional Commits format.** Every commit message must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification: `type(scope): description`, where type is one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.

7. **Always open a draft PR.** After the first push to a branch, open a pull request in draft status if one does not already exist. The PR title must also follow Conventional Commits format.

8. **Never log sensitive data.** Do not log or commit private keys, mnemonics, deployer secrets, or any user-identifying data. Keep secrets in environment variables / untracked files, never in source or fixtures.

9. **Comment non-obvious functions.** Add a detailed comment (NatSpec where appropriate) to any function whose logic is not immediately clear from its name alone — explaining what it does, why it works that way, and any non-obvious invariants or edge cases. Simple getters need no comment; access-control checks, accounting math, and external-call/reentrancy-sensitive paths do.

10. **Keep documentation and tests in sync.** After every change, update the documentation and tests present in the repo (README, NatSpec, Forge tests). Do not consider a task complete until all are consistent with the code.

11. **Keep all SDKs aligned when asked.** When asked to update the SDKs, check every SDK repo (`rail0-ruby`, `rail0-go`, `rail0-cli`) for alignment with the current gateway API surface. For each SDK: update client methods, README, and unit tests. Flag any SDK where alignment requires a breaking change.

12. **Align all tests when asked.** When asked to align or update tests, cover both layers: unit tests in every affected repo (gateway, indexer, all SDKs), and integration tests in `rail0-test` (API tests, flow tests for each SDK language, and cross-SDK tests). Verify that test fixtures, helper methods, and expected response shapes are consistent with the current gateway behaviour.

## Contract-specific conventions

`rail0` is the EVM smart contract (Solidity), built and tested with Foundry under `contracts/` (`src/`, `test/`, `script/`, `lib/`). Beyond the rules above, the following conventions are specific to this repo.

- **Solidity/Foundry idioms.** Follow the existing pragma, style, and NatSpec conventions. Use custom errors (not revert strings) consistent with the contract's existing error set; check-effects-interactions and reentrancy guards on state-changing external calls.
- **The contract is the source of truth for the protocol.** Its events, custom errors, and the payment struct are mirrored downstream — by the indexer's event handlers and by the SDKs' signing/decoding. Any change to an event signature, error, or struct **must be flagged** and coordinated with `rail0-indexer` and the SDKs (rule: cross-repo coordination).
- **Tests with Forge.** `forge build` and `forge test` (under `contracts/`) must pass; add/adjust tests for any behavioural change. Prefer fuzz/invariant tests for accounting and access-control logic.
- **Never commit deployer keys or RPC secrets.** Deployment scripts read them from the environment.
