# Contributing to Seqora

Thank you for your interest in contributing. This guide covers the workflow, standards, and expectations for all contributions.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started

1. Fork the repository
2. Clone your fork with submodules:
   ```bash
   git clone --recursive https://github.com/YOUR_USERNAME/seqora.git
   cd seqora/contracts
   forge build
   ```
3. Create a branch from `main`:
   ```bash
   git checkout -b feat/your-feature
   ```

See [contracts/README.md](contracts/README.md) for the full Solidity development setup.

## Development Workflow

1. **Branch from `main`.** One logical change per branch.
2. **Write tests alongside code.** New functionality requires tests. Bug fixes require a regression test.
3. **Format before committing:**
   ```bash
   forge fmt
   ```
4. **All tests must pass:**
   ```bash
   forge test
   ```
5. **Open a pull request against `main`.**

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add batch wet-lab attestation support
fix: prevent cross-tokenId replay in ProvenanceRegistry
test: add invariant suite for BiosafetyCourt
chore: update OpenZeppelin to v5.2.0
docs: document RoyaltyRouter hook integration
```

## Pull Request Standards

- Descriptive title following conventional commits
- Summary explaining **what** and **why**
- Test plan section (use the PR template)
- One logical change per PR
- CI must be green before merge

## Code Standards

### Solidity

- Custom errors only. No `require` with string messages.
- CEI (checks-effects-interactions) pattern on all state-mutating functions.
- NatSpec documentation on all public and external functions.
- `forge fmt` enforced by CI.
- No `console.log` in production contracts.

### TypeScript (frontend)

- ESLint and Prettier enforced.
- Functional components with TypeScript types.
- Tailwind CSS for styling.

## Issue Guidelines

- Search existing issues before opening a new one.
- Use the issue templates provided.
- Bug reports must include reproduction steps.
- Feature requests should describe the problem before the solution.

## Review Process

- All PRs require CI to pass (branch protection enforced).
- Contract changes in `contracts/src/` require maintainer review.
- Documentation and test-only changes can be self-merged after CI passes.

## Need Help?

- Open a [Discussion](https://github.com/SeqoraBase/seqora/discussions) for questions.
- Check existing issues for known problems.
- See [contracts/README.md](contracts/README.md) for build and test troubleshooting.
