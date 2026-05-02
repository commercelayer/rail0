# rail0
Peer-to-peer stablecoin payments for commerce.

## Design principles

1. Peer-to-peer
2. Never touch money
3. Virtually free

## Protocol

RAIL0 is a single Solidity contract (`contract/src/RAIL0.sol`) that brokers stablecoin payments on any EVM-compatible chain using the standard **authorize → capture → refund** lifecycle familiar from card networks. Each deployment is configured with an immutable allowlist of accepted ERC-20 stablecoins; no owner, no admin, no upgradeability, no protocol fee. The contract is a permissionless settlement primitive that two counterparties can use directly.

The intended deployment target is the emerging category of **stablecoin-gas chains** — chains where a stablecoin (USDC, USDT, EURC, …) is the native gas token, giving buyers and merchants a single-asset experience. Examples include Tempo, Arc, Plasma, Codex, and CELO.

### Lifecycle

A payment moves through three sequential time windows defined by the configuration the buyer and merchant agree on up front. Until `preApprovalExpiry`, the buyer can open the payment with either `authorize` (escrow funds for later capture) or `charge` (pay through immediately, no hold). Once authorized, the merchant has until `authorizationExpiry` to `capture` the escrowed funds — partially or in full, across one or more calls — or `void` the hold and release it back to the buyer; after that deadline the buyer can `reclaim` anything still in escrow. Captured funds stay reversible: until `refundExpiry`, the merchant can `refund` any portion back to the buyer. The expiries must satisfy `preApprovalExpiry ≤ authorizationExpiry ≤ refundExpiry`. Each operation is detailed below in lifecycle order.

#### Authorize

```solidity
function authorize(bytes32 paymentId, Payment calldata p, uint256 amount) external;
```

Buyer escrows `amount` of the stablecoin in the contract, holding it for the merchant to capture later.

Only `p.payer` may call. The buyer supplies a fresh, never-used `paymentId` and the full `Payment` configuration. The contract validates the config (expiries in order, fee within bounds, addresses non-zero, token in the deployment's allowlist), checks that `0 < amount ≤ p.maxAmount`, and that `block.timestamp < p.preApprovalExpiry`. It then computes the EIP-712 hash of `p` and stores it as the immutable terms of the payment, sets `capturableAmount = amount`, and pulls the tokens from the buyer via `transferFrom`. This requires the buyer to have approved RAIL0 on the token beforehand, or to use `permitAndAuthorize` to bundle the approval. Once authorized, the merchant may `capture` (one or more times, partial or full) before `authorizationExpiry`, or `void` at any time. If neither happens, the buyer's `reclaim` opens after `authorizationExpiry`.

#### Charge

```solidity
function charge(bytes32 paymentId, Payment calldata p, uint256 amount) external;
```

Buyer authorizes and pays through in a single call — no escrow hold.

Only `p.payer` may call. Preconditions are identical to `authorize` (fresh `paymentId`, valid amount, before `preApprovalExpiry`). The difference is settlement: instead of leaving funds in the contract, `charge` immediately calls `_distribute` to send `amount × feeBps / 10_000` to `feeReceiver` and the remainder to `payee`. State is recorded with `capturableAmount = 0` and `refundableAmount = amount`, so the merchant can still issue refunds against this payment until `refundExpiry`. Use this when the merchant doesn't need a separate fulfillment window — e.g. digital goods, instant services, or any flow where there is nothing to "capture later."

#### Capture

```solidity
function capture(bytes32 paymentId, Payment calldata p, uint256 amount) external;
```

Merchant pulls funds from escrow into their wallet (and any fee out to `feeReceiver`).

Only `p.payee` may call. Must run before `p.authorizationExpiry`, with `0 < amount ≤ capturableAmount`. State is updated atomically: `capturableAmount -= amount` and `refundableAmount += amount`, so refunds remain available against the captured slice until `refundExpiry`. Funds move via `_distribute`: `fee = amount × feeBps / 10_000` goes to `feeReceiver` and the remainder to `payee`, both as ERC-20 `transfer` calls. Captures may be partial and repeated — a merchant can split a single authorization across multiple captures (e.g. as items in an order ship over time) up to the originally authorized amount.

#### Void

```solidity
function void(bytes32 paymentId, Payment calldata p) external;
```

Merchant cancels the authorization, returning all currently-escrowed funds to the buyer.

Only `p.payee` may call. There is no deadline — the merchant can void any time `capturableAmount > 0`. The entire remaining escrow is sent back to the buyer in a single `transfer` call, and `capturableAmount` is zeroed. Voiding has no effect on `refundableAmount` — any previously captured slices remain refundable on their own timeline. Typical use: order rejected, fraud detected, or fulfillment canceled before any capture happened.

#### Reclaim

```solidity
function reclaim(bytes32 paymentId, Payment calldata p) external;
```

Buyer's safety net — pull escrowed funds back if the merchant never captured.

Only `p.payer` may call, and only after `block.timestamp >= p.authorizationExpiry`. Returns the full remaining `capturableAmount` (all-or-nothing) to the buyer and zeroes that slot. This is the buyer's only on-chain recourse if the merchant disappears — RAIL0 has no arbitration layer. Setting a sensible `authorizationExpiry` is therefore important for the buyer: it is the timestamp at which the merchant's "right to capture" ends and the buyer's "right to recover" begins.

#### Refund

```solidity
function refund(bytes32 paymentId, Payment calldata p, uint256 amount) external;
```

Merchant reverses a prior capture, sending `amount` of the stablecoin back to the buyer.

Only `p.payee` may call. Must run before `p.refundExpiry`, with `0 < amount ≤ refundableAmount`. State is updated: `refundableAmount -= amount`. Captured funds live in the merchant's wallet (not the contract), so `refund` calls `transferFrom(payee, payer, amount)` — **the merchant must keep an ERC-20 allowance to RAIL0 of at least `amount`**, or supply a permit signature via `permitAndRefund`. The merchant doesn't need any allowance for the happy path (`capture` distributes from contract-held escrow), only at refund time, so this requirement is easy to forget at integration time. Multiple partial refunds are supported up to the cumulative `refundableAmount`.

#### Permit-bundled variants

```solidity
function permitAndAuthorize(bytes32 paymentId, Payment calldata p, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
function permitAndCharge   (bytes32 paymentId, Payment calldata p, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
function permitAndRefund   (bytes32 paymentId, Payment calldata p, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
```

Each of the three transfer-pulling operations has a permit-bundled variant that calls `IERC20Permit.permit(...)` first, eliminating the separate approval transaction. The `permit` call is wrapped in `try/catch` and its failure is swallowed — this means the wrapper degrades gracefully on tokens that don't implement EIP-2612, on signatures that have been front-run (nonce advanced), and on callers who already have standing approval. If neither path provides allowance, the inner transfer reverts with the token's allowance error. `permitAndAuthorize` and `permitAndCharge` use the buyer's signature (`p.payer` is the permit owner); `permitAndRefund` uses the merchant's (`p.payee` is the owner).

### The `Payment` struct

A payment's terms are committed at authorization time and immutable thereafter. The struct is passed in calldata on every call and verified against a stored hash.

| Field                  | Type      | Meaning                                                          |
|------------------------|-----------|------------------------------------------------------------------|
| `payer`                | `address` | Buyer. Authorized to call `authorize`, `charge`, `reclaim`.      |
| `payee`                | `address` | Merchant. Authorized to call `capture`, `void`, `refund`.        |
| `token`                | `address` | ERC-20 stablecoin. Must be in the deployment's allowlist.        |
| `maxAmount`            | `uint120` | Upper bound on the amount the buyer can authorize.               |
| `preApprovalExpiry`    | `uint48`  | Cutoff for `authorize` / `charge`.                               |
| `authorizationExpiry`  | `uint48`  | Cutoff for `capture`; `reclaim` opens after this timestamp.      |
| `refundExpiry`         | `uint48`  | Cutoff for `refund`.                                             |
| `feeBps`               | `uint16`  | Fee in basis points (0–10000) taken on each capture.             |
| `feeReceiver`          | `address` | Recipient of the fee. Must be non-zero and not equal to either party when `feeBps > 0`. |

### State model

Per `paymentId`, the contract keeps two storage entries:

- `_state[paymentId]` — a packed slot containing `exists`, `capturableAmount`, `refundableAmount`. Once `exists` is set it never resets, preventing payment-ID reuse.
- `_configHash[paymentId]` — the EIP-712 digest of the `Payment` struct, set on first call and never mutated.

`capturableAmount` is funds **held in escrow** by the contract. `refundableAmount` is funds **already paid to the merchant** that are still reversible. `capture` moves money from the first bucket to the second (and out the door to the merchant); `refund` drains the second.

### Token allowlist

Each RAIL0 deployment is constructed with a fixed list of accepted ERC-20 token addresses. Calls to `authorize`/`charge` revert with `TokenNotAccepted` if `p.token` is not in the allowlist. The allowlist is set in the constructor and **cannot be modified afterward** — adding a new stablecoin requires a new deployment. This preserves the "no privileged roles, ever" property: there is no admin who can change which tokens RAIL0 will process.

A `TokenAccepted(address indexed token)` event is emitted from the constructor for each entry, so an indexer can reconstruct the allowlist from the deployment transaction's logs. `isAcceptedToken(address)` is a public view for the same query.

Practical implications:

- One deployment per `(chain, set of accepted tokens)`. A single deployment can accept multiple stablecoins (e.g., USDC + EURC) provided you list them at construction.
- When a chain adds a stablecoin you want to accept, deploy a new RAIL0 with the expanded list. Existing deployments continue to work for their original token set; new payments use the new deployment.
- Integrators should pin the RAIL0 address per chain and not assume cross-deployment compatibility.

### Config commitment (EIP-712)

The `Payment` struct is hashed with EIP-712 typed-data encoding using the domain `EIP712Domain(name="RAIL0", version="1", chainId, verifyingContract)`. The digest is stored at `_configHash[paymentId]` on first call (`authorize`/`charge`) and re-checked on every subsequent call via `_loadAndVerify`. Tampering with any field causes a `PaymentMismatch` revert.

The domain separator is cached at construction and rebuilt automatically if `block.chainid` changes (chain-fork safety). Two helpers expose the values to off-chain signers:

- `DOMAIN_SEPARATOR()` — current EIP-712 domain separator.
- `hashPayment(p)` — full digest matching what the contract stores.

### Allowance requirements

RAIL0 does not custody anything outside the active escrow window. Two parties may need to grant allowances:

- **Buyer.** Must approve RAIL0 (or sign a permit) before `authorize`/`charge` so the contract can pull escrow.
- **Merchant.** Must approve RAIL0 (or sign a permit) before `refund` so the contract can pull captured funds back from the merchant's wallet. This is non-obvious — the merchant never needs an allowance during the happy path (`capture` distributes from contract-held escrow), only at refund time.

The `permitAnd*` wrappers cover both cases via signature, removing the standing-approval requirement on tokens that implement EIP-2612.

### Events

Every lifecycle event indexes `paymentId`, `payer`, and `payee`, so indexers can filter by any party without a separate join:

```solidity
event TokenAccepted(address indexed token);

event PaymentAuthorized(bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment, uint256 amount);
event PaymentCharged   (bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment, uint256 amount);
event PaymentCaptured  (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
event PaymentVoided    (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
event PaymentReclaimed (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
event PaymentRefunded  (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
```

To correlate token transfers with a `paymentId`, indexers join the token's `Transfer` events with RAIL0's lifecycle events on transaction hash and log ordering — the lifecycle event always lands in the same transaction as its corresponding transfers.

### Errors

| Error                       | Cause                                                              |
|-----------------------------|--------------------------------------------------------------------|
| `NotPayer` / `NotPayee`     | Caller is not the authorized party for the operation.              |
| `PaymentAlreadyExists`      | `paymentId` was already used.                                      |
| `PaymentNotFound`           | `paymentId` has no state.                                          |
| `PaymentMismatch`           | The `Payment` struct passed in does not match the stored hash.     |
| `InvalidAmount`             | `amount == 0` or `amount > p.maxAmount`.                           |
| `AmountTooLarge`            | `p.maxAmount > type(uint120).max`.                                 |
| `InvalidExpiries`           | Expiries are zero or out of order.                                 |
| `PreApprovalExpired`        | `block.timestamp >= p.preApprovalExpiry` at authorize/charge.      |
| `AuthorizationExpired`      | `block.timestamp >= p.authorizationExpiry` at capture.             |
| `AuthorizationNotExpired`   | `reclaim` called before `authorizationExpiry`.                     |
| `RefundExpired`             | `block.timestamp >= p.refundExpiry` at refund.                     |
| `FeeBpsTooHigh`             | `p.feeBps > 10000`.                                                |
| `ZeroFeeReceiver`           | `feeBps > 0` and `feeReceiver == address(0)`.                      |
| `FeeReceiverIsParty`        | `feeBps > 0` and `feeReceiver` equals `payer` or `payee`.          |
| `ZeroAddress`               | `payer`, `payee`, or `token` is the zero address.                  |
| `InvalidCaptureAmount`      | `amount == 0` or `amount > capturableAmount`.                      |
| `InvalidRefundAmount`       | `amount == 0` or `amount > refundableAmount`.                      |
| `NothingToVoid`             | `void` called with `capturableAmount == 0`.                        |
| `NothingToReclaim`          | `reclaim` called with `capturableAmount == 0`.                     |
| `TokenNotAccepted`          | `p.token` is not in the deployment's allowlist.                    |
| `DuplicateToken`            | Constructor `acceptedTokens` contained the same address twice.     |
| `TransferFailed`            | A token `transfer` / `transferFrom` returned `false` or reverted.  |
| `Reentrancy`                | A nested call attempted to reenter a guarded entrypoint.           |

### Security model

- **No privileged roles.** No owner, no pauser, no upgrade path. The contract code is fixed at deploy time. The token allowlist is set in the constructor and immutable thereafter.
- **Curated trust boundary.** The deployer chooses which tokens RAIL0 will process. Including a hostile or weird ERC-20 in the allowlist is the deployer's risk to manage — the contract trusts allowlisted tokens to behave like standard ERC-20s.
- **Reentrancy guard.** All nine entrypoints (`authorize`, `charge`, `capture`, `void`, `reclaim`, `refund`, and the three `permitAnd*` wrappers) are protected by a `nonReentrant` modifier. Any attempt to reenter from inside a token call reverts with `Reentrancy`.
- **Checks-Effects-Interactions.** All state mutations occur before external transfers. Even if the reentrancy guard were bypassed (it can't be) the CEI ordering already prevents same-payment double-spending.
- **SafeERC20-style transfers.** `_safeTransfer` / `_safeTransferFrom` accept both bool-returning and non-returning ERC-20 implementations, and revert with `TransferFailed` on any failure. Compatible with USDT-mainnet-style tokens that don't return a value.
- **Caller-supplied `paymentId`.** The contract enforces uniqueness (`PaymentAlreadyExists`) but does not generate IDs. Integrators should use a collision-resistant scheme (UUID, `keccak256(payer, payee, nonce)`, etc.).
- **Time-based dispute resolution only.** The protocol has no arbitration layer; the buyer's recourse is `reclaim` after `authorizationExpiry`. Any other dispute handling is off-chain.
- **Test coverage.** A 48-test Foundry suite (`contract/test/RAIL0.t.sol`) covers the lifecycle, allowlist construction, every revert path, EIP-712 hashing, permit wrappers (success + fallback), reentrancy attempts via a malicious mock token, and USDT-style non-returning tokens. No external audit has been performed.

### Limits

- Per-payment amounts are capped at `type(uint120).max` (≈ 1.3 × 10³⁶, or 1.3 × 10³⁰ at 6 decimals — effectively unbounded for stablecoins).
- An authorization cannot be topped up or extended; needing more requires a new `paymentId`.
- `reclaim` and `void` are all-or-nothing — they always release the entire remaining `capturableAmount`.
- `paymentId` slots are never deleted; reusing an ID always reverts.
- The token allowlist is fixed at deployment; new stablecoins require a new deployment.

### Deployments

| Chain | RAIL0 address | Accepted tokens |
|-------|---------------|-----------------|
| _none yet_ | | |

## Development

The contract lives at `contract/src/RAIL0.sol`. The Foundry workspace is rooted at `contract/`.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)

### Cloning

The repo uses `forge-std` as a git submodule, so clone with `--recurse-submodules` (or run `git submodule update --init --recursive` after cloning).

### Build & test

```sh
cd contract
forge build
forge test
```

The test suite (`contract/test/RAIL0.t.sol`) is self-contained — it includes mock ERC-20 implementations for the standard, USDT-style (no return value), reverting, and reentrant cases, so no fork or RPC is needed.

### Layout

```
contract/
├── foundry.toml
├── src/
│   ├── RAIL0.sol               # the protocol contract
│   └── interfaces/IERC20.sol   # IERC20 + IERC20Permit
└── test/
    └── RAIL0.t.sol             # full test suite + mocks
```
