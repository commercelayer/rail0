<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo/rail0_payoff_white.svg">
  <img src="logo/rail0_payoff_black.svg" alt="RAIL0 — Peer-to-peer stablecoin payments for commerce" width="400">
</picture>

---

The internet runs on open protocols — HTTP, DNS, SMTP — that anyone can implement, run, and build on without permission. Payments are the conspicuous exception. Online commerce today still routes through a layered stack of intermediaries (networks, processors, gateways, issuers, acquirers), each taking a fee, adding latency, and reserving the right to refuse service. Cross-border settlement is slow and expensive. Refunds and disputes happen off-rail. Programmable money, twenty years into the API economy, is still mostly marketing.

Stablecoins changed the substrate. A dollar can move between two wallets in under a second, anywhere in the world, for fractions of a cent, without anyone's permission. But a transfer alone isn't commerce. Commerce needs the primitives card networks have always provided — authorization, capture, refund, dispute windows — around the bare movement of money. So far, the only way to get those primitives has been to plug back into the legacy stack and inherit its costs.

RAIL0 is the alternative: a single immutable smart contract that implements the full authorize → capture → refund lifecycle for stablecoin payments, with no owner, no admin, no fee, and no privileged operator. Anyone can deploy it. Anyone can use it. Buyer-initiated operations work like a signed check: the buyer signs a per-payment authorization off-chain, the merchant submits the transaction, and the merchant pays gas natively in the chain's stablecoin. No bundlers, no smart-account wallets required, no separate paymaster — buyer keeps any wallet that signs typed data, merchant absorbs the cost of acceptance the way they always have under card networks. RAIL0 accepts any ERC-20 stablecoin and adds nothing between buyer and merchant beyond the rules of the contract itself — rules that are public, immutable, and the same for everyone.

Payment rails should be open like the rest of the internet. That is the mission. The zero in RAIL0 is literal: zero intermediaries between buyer and merchant, zero protocol fees, zero privileged operators, zero permission required to deploy or to use. It also marks day zero — the moment payments stop being a service rented from someone else's network and become a commodity protocol the way HTTP is. If we get this right, RAIL0 is the last payment rail the new era needs. The rest is just integration.

## Supported chains

RAIL0 is built for **stablecoin-gas L1 chains with sub-second finality**, accepting tokens that implement **EIP-3009 (`transferWithAuthorization`)**. Concretely:

- **EVM-compatible.** Solidity 0.8.27 must compile and execute on the chain.
- **Stablecoin-native gas.** The chain's native gas token is a regulated stablecoin (USDC, USDT, EURC, etc.). Merchants pay gas in the same asset they're settling in — no second gas-token to manage.
- **L1 sovereignty.** No sequencer dependency, no withdrawal delays, no inherited security from another chain.
- **Sub-second finality.** Online checkout doesn't tolerate multi-second confirmation times.
- **EIP-3009-capable tokens.** Each accepted token must expose `transferWithAuthorization` so the buyer can authorize transfers off-chain. USDC supports EIP-3009 on every chain; Plasma's USDT0 supports it; some legacy USDT deployments don't.

Currently targeted:

| Chain | Status | Native gas | RAIL0 deployment |
|-------|--------|------------|------------------|
| Tempo | planned | USDC (TIP-20) | _none yet_ |
| Arc | planned | USDC | _none yet_ |
| Plasma | planned | USDT | _none yet_ |
| Codex | planned | USDC | _none yet_ |

Chains explicitly NOT supported: anything without stablecoin-native gas (Ethereum mainnet, Base, Arbitrum, Optimism, Polygon, etc.), L2s with sequencer-controlled finality.

## Protocol

RAIL0 is a permissionless, peer-to-peer payment protocol for stablecoin commerce. It implements the authorize → capture → refund lifecycle familiar from card networks as a single immutable smart contract: buyers and merchants transact directly, the protocol never custodies payment funds outside the active escrow window, and there is no owner, no admin, no upgradeability, and no protocol fee. Buyer-initiated operations use a single off-chain signature: the buyer signs an **EIP-3009 `TransferWithAuthorization`** over the token's domain, anyone (typically the merchant) submits the transaction, and the submitter pays gas natively. No allowance is granted, no separate intent typehash, no token approval — one signature, one transaction, no broadcasted setup from the buyer.

### Lifecycle

A payment moves through three sequential time windows defined by the configuration the buyer and merchant agree on up front. Until `preApprovalExpiry`, the payment can be opened with either `authorize` (escrow funds for later capture) or `charge` (pay through immediately, no hold) — the buyer signs the intent off-chain, the merchant (or anyone) submits the transaction. Once authorized, the merchant has until `authorizationExpiry` to `capture` the escrowed funds — partially or in full, across one or more calls — or `void` the hold and return it to the buyer; after that deadline anyone may submit `release` to return the remaining escrow to the buyer. Captured funds stay reversible: until `refundExpiry`, the merchant can `refund` any portion back to the buyer. The expiries must satisfy `preApprovalExpiry ≤ authorizationExpiry ≤ refundExpiry`. Each operation is detailed below in lifecycle order.

#### Authorize

```solidity
function authorize(
    bytes32 paymentId,
    Payment calldata p,
    uint256 amount,
    uint256 validAfter,
    uint256 validBefore,
    uint8 v,
    bytes32 r,
    bytes32 s
) external;
```

Buyer escrows `amount` of the stablecoin in the contract, holding it for the merchant to capture later.

The buyer signs an **EIP-3009 `TransferWithAuthorization`** over the token's domain with `from = p.payer`, `to = address(rail0)`, `value = amount`, and `nonce = keccak256(_AUTHORIZE_NONCE_PREFIX, paymentId, configHash)`. The merchant submits this transaction. The contract validates the config (expiries in order, fee within bounds, addresses non-zero, token in the deployment's allowlist), records the payment state, then calls `token.transferWithAuthorization(...)` with the deterministic nonce. The token's own EIP-712 sig check verifies the buyer's signature; if anything was tampered (different Payment terms, different amount, different recipient), the recovered signer won't match `p.payer` and the token reverts. The deterministic-nonce trick is what binds the buyer's signature to the exact Payment terms — no separate intent typehash needed. Once authorized, the merchant may `capture` (one or more times, partial or full) before `authorizationExpiry`, or `void` at any time. If neither happens, `release` opens after `authorizationExpiry`.

#### Charge

```solidity
function charge(
    bytes32 paymentId,
    Payment calldata p,
    uint256 amount,
    uint256 validAfter,
    uint256 validBefore,
    uint8 v,
    bytes32 r,
    bytes32 s
) external;
```

Buyer authorizes and pays through in a single call — no escrow hold.

Same EIP-3009 pattern as `authorize`, but the contract derives the nonce with `_CHARGE_NONCE_PREFIX` instead. A buyer's authorize-signature cannot be used to call `charge` (and vice versa) because the two derived nonces differ — the token would compute a different nonce when verifying and the recovered signer would not match. Preconditions are otherwise identical (fresh `paymentId`, valid amount, before `preApprovalExpiry`). The difference is settlement: instead of leaving funds in the contract, `charge` immediately calls `_distribute` to send `amount × feeBps / 10_000` to `feeReceiver` and the remainder to `payee`. State is recorded with `capturableAmount = 0` and `refundableAmount = amount`, so the merchant can still issue refunds against this payment until `refundExpiry`. Use this when the merchant doesn't need a separate fulfillment window — e.g. digital goods, instant services, or any flow where there is nothing to "capture later."

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

#### Release

```solidity
function release(bytes32 paymentId, Payment calldata p) external;
```

Buyer's safety net — return escrowed funds to the buyer if the merchant never captured.

**Anyone may call** — funds always go to `p.payer` regardless of who submits, so there is no theft potential and the buyer doesn't need to hold the chain's gas asset to recover their funds. A relayer or watchdog service can submit the release on the buyer's behalf. Only callable after `block.timestamp >= p.authorizationExpiry`. Returns the full remaining `capturableAmount` (all-or-nothing) and zeroes that slot. This is the buyer's only on-chain recourse if the merchant disappears — RAIL0 has no arbitration layer. Setting a sensible `authorizationExpiry` is therefore important for the buyer: it is the timestamp at which the merchant's "right to capture" ends and the buyer's "right to recover" begins.

#### Refund

```solidity
function refund(bytes32 paymentId, Payment calldata p, uint256 amount) external;
```

Merchant reverses a prior capture, sending `amount` of the stablecoin back to the buyer.

Only `p.payee` may call. Must run before `p.refundExpiry`, with `0 < amount ≤ refundableAmount`. State is updated: `refundableAmount -= amount`. Captured funds live in the merchant's wallet (not the contract), so `refund` calls `transferFrom(payee, payer, amount)` — **the merchant must keep an ERC-20 allowance to RAIL0 of at least `amount`**. The merchant is the on-chain submitter here, so they manage their own approval (typically `token.approve(rail0, max)` once at onboarding); no off-chain authorization signature is needed because they're broadcasting the tx anyway.

### The `Payment` struct

A payment's terms are committed at authorization time and immutable thereafter. The struct is passed in calldata on every call and verified against a stored hash.

| Field                  | Type      | Meaning                                                          |
|------------------------|-----------|------------------------------------------------------------------|
| `payer`                | `address` | Buyer. Source of escrowed funds; signer of the EIP-3009 `TransferWithAuthorization` off-chain. |
| `payee`                | `address` | Merchant. Calls `capture`, `void`, `refund`. Recipient of captured funds. |
| `token`                | `address` | ERC-20 stablecoin. Must be in the deployment's allowlist.        |
| `maxAmount`            | `uint120` | Upper bound on the amount the buyer can authorize.               |
| `preApprovalExpiry`    | `uint48`  | Cutoff for `authorize` / `charge`.                               |
| `authorizationExpiry`  | `uint48`  | Cutoff for `capture`; `release` opens after this timestamp.      |
| `refundExpiry`         | `uint48`  | Cutoff for `refund`.                                             |
| `feeBps`               | `uint16`  | Fee in basis points (0–10000) taken on each capture.             |
| `feeReceiver`          | `address` | Recipient of the fee. Must be non-zero and not equal to either party when `feeBps > 0`. |

### State model

Per `paymentId`, the contract keeps two storage entries:

- `_state[paymentId]` — a packed slot containing `exists`, `capturableAmount`, `refundableAmount`. Once `exists` is set it never resets, preventing payment-ID reuse.
- `_configHash[paymentId]` — the EIP-712 digest of the `Payment` struct, set on first call and never mutated.

`capturableAmount` is funds **held in escrow** by the contract. `refundableAmount` is funds **already paid to the merchant** that are still reversible. `capture` moves money from the first bucket to the second (and out the door to the merchant); `refund` drains the second.

### Token allowlist

Each RAIL0 deployment is constructed with a fixed list of accepted ERC-20 token addresses. Calls to `authorize`/`charge` revert with `TokenNotAccepted` if `p.token` is not in the allowlist. The allowlist is set in the constructor and **cannot be modified afterward** — adding a new stablecoin requires a new deployment.

A `TokenAccepted(address indexed token)` event is emitted from the constructor for each entry, so an indexer can reconstruct the allowlist from the deployment transaction's logs. `isAcceptedToken(address)` is a public view for the same query.

Practical implications:

- One deployment per `(chain, set of accepted tokens)`. A single deployment can accept multiple stablecoins (e.g., USDC + EURC) provided you list them at construction.
- When a chain adds a stablecoin you want to accept, deploy a new RAIL0 with the expanded list. Existing deployments continue to work for their original token set; new payments use the new deployment.
- Integrators should pin the RAIL0 address per chain and not assume cross-deployment compatibility.

### Config commitment (EIP-712)

The `Payment` struct is hashed with EIP-712 typed-data encoding using the domain `EIP712Domain(name="RAIL0", version="3", chainId, verifyingContract)`. The digest is stored at `_configHash[paymentId]` on first call (`authorize`/`charge`) and re-checked on every subsequent call via `_loadAndVerify`. Tampering with any field causes a `PaymentMismatch` revert.

Buyer-initiated operations don't introduce a separate RAIL0-domain signing typehash. Instead, RAIL0 derives a deterministic EIP-3009 nonce from the operation context:

```
authorizeNonce = keccak256(keccak256("RAIL0.AUTHORIZE"), paymentId, configHash)
chargeNonce    = keccak256(keccak256("RAIL0.CHARGE"),    paymentId, configHash)
```

The buyer signs the token's standard `TransferWithAuthorization` digest with this nonce. The merchant submits, RAIL0 recomputes the nonce from the supplied Payment, and calls `token.transferWithAuthorization(...)`. If the merchant tampered with any Payment field, the recomputed nonce differs, the recovered signer differs from `p.payer`, and the token reverts. The configHash inside the nonce derivation provides the same term-binding that an EIP-712 intent typehash would, without needing one.

Distinct prefixes ensure an authorize-signature can't be reused for charge — the nonces don't match.

The domain separator is cached at construction and rebuilt automatically if `block.chainid` changes (chain-fork safety). Helpers exposed to off-chain signers:

- `DOMAIN_SEPARATOR()` — current EIP-712 domain separator (used only for `Payment` hashing; the buyer signs over the *token's* domain).
- `hashPayment(p)` — Payment digest (also stored on-chain as configHash).
- `authorizeNonce(paymentId, configHash)` — EIP-3009 nonce the buyer must use when signing for `authorize`.
- `chargeNonce(paymentId, configHash)` — EIP-3009 nonce the buyer must use when signing for `charge`.

### Allowance requirements

RAIL0 does not custody anything outside the active escrow window. Token approvals work asymmetrically between the two parties:

- **Buyer.** **No allowance grant ever happens.** EIP-3009's `transferWithAuthorization` moves funds from the buyer's wallet to RAIL0 atomically based on the buyer's signature alone. The buyer never calls `approve`, never grants an allowance, never broadcasts any transaction.
- **Merchant.** Must approve RAIL0 once on the token before issuing refunds (`refund` calls `transferFrom(payee, payer, amount)`). The merchant is the on-chain submitter for refund anyway, so they manage their own approval — typically `token.approve(rail0, max)` once at onboarding. Not needed for `capture` / `void` / `release` (those distribute or move funds RAIL0 already holds).

### Events

Every lifecycle event indexes `paymentId`, `payer`, and `payee`, so indexers can filter by any party without a separate join:

```solidity
event TokenAccepted(address indexed token);

event PaymentAuthorized(bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment, uint256 amount);
event PaymentCharged   (bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment, uint256 amount);
event PaymentCaptured  (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
event PaymentVoided    (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
event PaymentReleased  (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
event PaymentRefunded  (bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
```

To correlate token transfers with a `paymentId`, indexers join the token's `Transfer` events with RAIL0's lifecycle events on transaction hash and log ordering — the lifecycle event always lands in the same transaction as its corresponding transfers.

### Errors

| Error                       | Cause                                                              |
|-----------------------------|--------------------------------------------------------------------|
| `NotPayee`                  | Caller is not the merchant for a merchant-only operation.          |
| `PaymentAlreadyExists`      | `paymentId` was already used.                                      |
| `PaymentNotFound`           | `paymentId` has no state.                                          |
| `PaymentMismatch`           | The `Payment` struct passed in does not match the stored hash.     |
| `InvalidAmount`             | `amount == 0` or `amount > p.maxAmount`.                           |
| `AmountTooLarge`            | `p.maxAmount > type(uint120).max`.                                 |
| `InvalidExpiries`           | Expiries are zero or out of order.                                 |
| `PreApprovalExpired`        | `block.timestamp >= p.preApprovalExpiry` at authorize/charge.      |
| `AuthorizationExpired`      | `block.timestamp >= p.authorizationExpiry` at capture.             |
| `AuthorizationNotExpired`   | `release` called before `authorizationExpiry`.                     |
| `RefundExpired`             | `block.timestamp >= p.refundExpiry` at refund.                     |
| `FeeBpsTooHigh`             | `p.feeBps > 10000`.                                                |
| `ZeroFeeReceiver`           | `feeBps > 0` and `feeReceiver == address(0)`.                      |
| `FeeReceiverIsParty`        | `feeBps > 0` and `feeReceiver` equals `payer` or `payee`.          |
| `ZeroAddress`               | `payer`, `payee`, or `token` is the zero address.                  |
| `InvalidCaptureAmount`      | `amount == 0` or `amount > capturableAmount`.                      |
| `InvalidRefundAmount`       | `amount == 0` or `amount > refundableAmount`.                      |
| `NothingToVoid`             | `void` called with `capturableAmount == 0`.                        |
| `NothingToRelease`          | `release` called with `capturableAmount == 0`.                     |
| `TokenNotAccepted`          | `p.token` is not in the deployment's allowlist.                    |
| `DuplicateToken`            | Constructor `acceptedTokens` contained the same address twice.     |
| `TransferFailed`            | A token `transfer` / `transferFrom` returned `false` or reverted.  |
| `Reentrancy`                | A nested call attempted to reenter a guarded entrypoint.           |

### Security model

- **No privileged roles.** No owner, no pauser, no upgrade path. The contract code is fixed at deploy time. The token allowlist is set in the constructor and immutable thereafter.
- **Curated trust boundary.** The deployer chooses which tokens RAIL0 will process. Including a hostile or weird ERC-20 in the allowlist is the deployer's risk to manage — the contract trusts allowlisted tokens to behave like standard ERC-20s.
- **Reentrancy guard.** All six entrypoints (`authorize`, `charge`, `capture`, `void`, `release`, `refund`) are protected by a `nonReentrant` modifier. Any attempt to reenter from inside a token call reverts with `Reentrancy`.
- **Checks-Effects-Interactions.** All state mutations occur before external transfers. Even if the reentrancy guard were bypassed (it can't be) the CEI ordering already prevents same-payment double-spending.
- **SafeERC20-style transfers.** `_safeTransfer` / `_safeTransferFrom` accept both bool-returning and non-returning ERC-20 implementations, and revert with `TransferFailed` on any failure. Compatible with USDT-mainnet-style tokens that don't return a value.
- **Caller-supplied `paymentId`.** The contract enforces uniqueness (`PaymentAlreadyExists`) but does not generate IDs. Integrators should use a collision-resistant scheme (UUID, `keccak256(payer, payee, nonce)`, etc.).
- **Time-based dispute resolution only.** The protocol has no arbitration layer; the buyer's recourse is `release` after `authorizationExpiry`. Any other dispute handling is off-chain.
- **Test coverage.** A 98-test Foundry suite (`contracts/test/RAIL0.t.sol`) covers the full lifecycle, allowlist construction, every revert path on every entrypoint (`PaymentNotFound`, `PaymentMismatch`, `NotPayee`, all amount/expiry/fee validation), EIP-712 hashing determinism, EIP-3009 nonce derivation and signature verification (wrong signer, tampered amount, tampered Payment, expired `validBefore`, not-yet-valid `validAfter`, wrong nonce prefix, paymentId-replay protection), `_safeTransfer` / `_safeTransferFrom` failure handling on bool=false-returning tokens, distribute-fee rounding edge cases, boundary conditions (equal expiries, max feeBps, amount equals maxAmount, exact authorizationExpiry), reentrancy attempts via a malicious mock token, and anyone-can-submit verification on `release`. No external audit has been performed.

### Limits

- Per-payment amounts are capped at `type(uint120).max` (≈ 1.3 × 10³⁶, or 1.3 × 10³⁰ at 6 decimals — effectively unbounded for stablecoins).
- An authorization cannot be topped up or extended; needing more requires a new `paymentId`.
- `release` and `void` are all-or-nothing — they always return the entire remaining `capturableAmount` to the buyer.
- `paymentId` slots are never deleted; reusing an ID always reverts.
- The token allowlist is fixed at deployment; new stablecoins require a new deployment.

### Deployments

| Chain | RAIL0 address | Accepted tokens |
|-------|---------------|-----------------|
| _none yet_ | | |

### Gas sponsorship

There is no separate sponsorship layer in RAIL0. Sponsorship is just "the merchant submits the transaction" — the meta-transaction pattern handles it for free.

The mechanics: the buyer signs an EIP-3009 `TransferWithAuthorization` over the token's domain off-chain. The merchant (or any third party) takes that signature plus the Payment terms and submits a regular Ethereum transaction calling `authorize` / `charge`. The submitter is the `tx.origin`, so the submitter pays gas natively in the chain's gas asset. On stablecoin-gas chains, that's the same stablecoin the merchant is settling in — no second asset to manage.

**Who can sponsor?**

Anyone willing to submit the transaction. The protocol doesn't track sponsors, doesn't require deposits, doesn't validate sponsor identity. Common patterns:

- **Merchant submits.** The most common case. Merchant runs a checkout backend that takes the buyer's signed intent + Payment terms and submits the tx. Merchant absorbs gas as a cost of acceptance, exactly like card interchange.
- **Platform / payment facilitator submits.** A platform aggregating many merchants can run a single relayer that submits txs for all of them. Bills the merchants off-chain.
- **Third-party relayer submits.** Anyone with stablecoin balance and a will to pay gas. Could be a grant-funded relayer subsidizing categories of transactions.
- **Buyer submits themselves.** Always allowed — the buyer can sign + submit in one go if they prefer. Wallet shows two prompts (sign typed data, then submit transaction). Useful when the buyer doesn't trust any specific merchant/relayer to submit.

In all cases, **the submitter pays gas, the buyer never broadcasts a transaction**, and the buyer's wallet only ever signs typed data.

**What about release?**

`release` is callable by anyone (not just the buyer). Funds always go to `p.payer` regardless of submitter, so there is no theft potential. A buyer who has been ghosted by the merchant doesn't need to hold the chain's gas asset to recover their funds — a relayer or watchdog service can submit the release on their behalf.

## Examples

End-to-end `cast` recipes for every workflow. Examples use `--private-key` for readability — in production, prefer `cast wallet import <name>` once and then `--account <name>` on each command (never put long-lived keys on the command line).

### Setup

Set the addresses and keys you'll reuse:

```sh
export RPC=https://rpc.example.network
export RAIL0=0x...                  # the RAIL0 deployment
export TOKEN=0x...                  # an accepted stablecoin
export PAYER=0x...                  # buyer wallet
export PAYEE=0x...                  # merchant wallet
export FEE_RCV=0x...                # fee receiver (or 0x0 if feeBps == 0)
export PAYER_KEY=0x...              # buyer signing key (signs EIP-3009 TransferWithAuthorization off-chain)
export PAYEE_KEY=0x...              # merchant signing key (submits txs)
```

The `Payment` struct is a 9-field tuple. Define it once and reuse:

```sh
# (payer, payee, token, maxAmount, preApprovalExpiry, authorizationExpiry, refundExpiry, feeBps, feeReceiver)
export PAYMENT="($PAYER,$PAYEE,$TOKEN,1000000000,1735689600,1736294400,1738972800,250,$FEE_RCV)"
export PAYMENT_TYPE='(address,address,address,uint120,uint48,uint48,uint48,uint16,address)'
export PAYMENT_ID=$(cast keccak "order-12345")
```

### One-time merchant approval

The buyer never needs to call `approve` — EIP-3009 doesn't touch allowance. The merchant does need to approve RAIL0 once, because captured funds live in the merchant's own wallet (not in the contract), so refunds work by pulling from there via `transferFrom` — which requires a standing allowance:

```sh
cast send $TOKEN "approve(address,uint256)" $RAIL0 $(cast max-uint) \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Authorize (buyer signs EIP-3009, merchant submits)

The buyer signs an EIP-3009 `TransferWithAuthorization` over the token's domain. The merchant submits and pays gas. In production a wallet SDK handles the EIP-712 signing; the cast equivalent below builds the digest manually.

```sh
# 1. Compute the deterministic EIP-3009 nonce that RAIL0 expects
CONFIG_HASH=$(cast call $RAIL0 "hashPayment($PAYMENT_TYPE)(bytes32)" "$PAYMENT" --rpc-url $RPC)
NONCE=$(cast call $RAIL0 "authorizeNonce(bytes32,bytes32)(bytes32)" \
  $PAYMENT_ID $CONFIG_HASH --rpc-url $RPC)

# 2. Pick a validity window
VALID_AFTER=0
VALID_BEFORE=$(($(date +%s) + 600))   # 10 minutes from now
AMOUNT=100000000                       # 100 USDC at 6 decimals

# 3. Build the EIP-3009 TransferWithAuthorization digest (over the TOKEN's domain)
TOKEN_DOMAIN=$(cast call $TOKEN "DOMAIN_SEPARATOR()(bytes32)" --rpc-url $RPC)
TWA_TYPEHASH=$(cast keccak \
  "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
STRUCT_HASH=$(cast keccak $(cast abi-encode \
  "f(bytes32,address,address,uint256,uint256,uint256,bytes32)" \
  $TWA_TYPEHASH $PAYER $RAIL0 $AMOUNT $VALID_AFTER $VALID_BEFORE $NONCE))
DIGEST=$(cast keccak 0x1901${TOKEN_DOMAIN:2}${STRUCT_HASH:2})

# 4. Buyer signs the raw digest
SIG=$(cast wallet sign --no-hash --private-key $PAYER_KEY $DIGEST)

# 5. Split into v, r, s for the call
R=0x${SIG:2:64}
S=0x${SIG:66:64}
V=0x${SIG:130:2}

# 6. Merchant submits the transaction and pays gas
cast send $RAIL0 \
  "authorize(bytes32,$PAYMENT_TYPE,uint256,uint256,uint256,uint8,bytes32,bytes32)" \
  $PAYMENT_ID "$PAYMENT" $AMOUNT $VALID_AFTER $VALID_BEFORE $V $R $S \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

In production, the buyer's wallet (Metamask, Rabby, hardware) renders this as a standard EIP-3009 `TransferWithAuthorization` prompt and signs via `eth_signTypedData_v4`. No separate intent typehash is needed — the deterministic nonce binds the signature to the Payment terms.

### Capture (merchant)

```sh
# Full capture
cast send $RAIL0 "capture(bytes32,$PAYMENT_TYPE,uint256)" \
  $PAYMENT_ID "$PAYMENT" 100000000 \
  --rpc-url $RPC --private-key $PAYEE_KEY

# Partial capture (can be called multiple times up to original amount)
cast send $RAIL0 "capture(bytes32,$PAYMENT_TYPE,uint256)" \
  $PAYMENT_ID "$PAYMENT" 30000000 \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Refund (merchant)

Pulls from merchant's own wallet back to buyer. Requires the merchant's standing ERC-20 approval set up at onboarding (see [One-time merchant approval](#one-time-merchant-approval)).

```sh
cast send $RAIL0 "refund(bytes32,$PAYMENT_TYPE,uint256)" \
  $PAYMENT_ID "$PAYMENT" 50000000 \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Charge (buyer signs EIP-3009, merchant submits — one-shot pay-through)

Skip escrow; pay merchant immediately. Refunds remain available until `refundExpiry`. Identical pattern to Authorize but the buyer derives the nonce with `chargeNonce` instead of `authorizeNonce` (so an authorize-signature can't be repurposed for charge):

```sh
NONCE=$(cast call $RAIL0 "chargeNonce(bytes32,bytes32)(bytes32)" \
  $PAYMENT_ID $CONFIG_HASH --rpc-url $RPC)

# Build digest with the new nonce, sign, split, then:
cast send $RAIL0 \
  "charge(bytes32,$PAYMENT_TYPE,uint256,uint256,uint256,uint8,bytes32,bytes32)" \
  $PAYMENT_ID "$PAYMENT" $AMOUNT $VALID_AFTER $VALID_BEFORE $V $R $S \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Void (merchant cancels authorization)

Returns all currently-escrowed funds to the buyer. No deadline.

```sh
cast send $RAIL0 "void(bytes32,$PAYMENT_TYPE)" \
  $PAYMENT_ID "$PAYMENT" \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Release (anyone — public after authorizationExpiry)

After `authorizationExpiry`, if no capture happened, anyone can submit `release` and the funds go to `p.payer`:

```sh
# A relayer / watchdog / the buyer themselves — any signing key works
cast send $RAIL0 "release(bytes32,$PAYMENT_TYPE)" \
  $PAYMENT_ID "$PAYMENT" \
  --rpc-url $RPC --private-key $RELAYER_KEY
```

### Reading state

Payment state (returns `(bool exists, uint120 capturable, uint120 refundable)`):

```sh
cast call $RAIL0 "getPaymentState(bytes32)((bool,uint120,uint120))" \
  $PAYMENT_ID --rpc-url $RPC
```

Stored config hash:

```sh
cast call $RAIL0 "getConfigHash(bytes32)(bytes32)" \
  $PAYMENT_ID --rpc-url $RPC
```

Compute the digests and nonces the contract uses:

```sh
# Payment EIP-712 digest (matches getConfigHash after authorize)
cast call $RAIL0 "hashPayment($PAYMENT_TYPE)(bytes32)" "$PAYMENT" --rpc-url $RPC

# EIP-3009 nonce for an `authorize` call
cast call $RAIL0 "authorizeNonce(bytes32,bytes32)(bytes32)" \
  $PAYMENT_ID $CONFIG_HASH --rpc-url $RPC

# EIP-3009 nonce for a `charge` call
cast call $RAIL0 "chargeNonce(bytes32,bytes32)(bytes32)" \
  $PAYMENT_ID $CONFIG_HASH --rpc-url $RPC
```

Domain separator and allowlist check:

```sh
cast call $RAIL0 "DOMAIN_SEPARATOR()(bytes32)" --rpc-url $RPC
cast call $RAIL0 "isAcceptedToken(address)(bool)" $TOKEN --rpc-url $RPC
```

## Development

The contract lives at `contracts/src/RAIL0.sol`. The Foundry workspace is rooted at `contracts/`.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)

### Cloning

The repo uses `forge-std` as a git submodule, so clone with `--recurse-submodules` (or run `git submodule update --init --recursive` after cloning).

### Build & test

```sh
cd contracts
forge build
forge test
```

The test suite (`contracts/test/RAIL0.t.sol`) is self-contained — it includes mock ERC-20 implementations for the standard, USDT-style (no return value), reverting, and reentrant cases, so no fork or RPC is needed.

### Layout

```
contracts/
├── foundry.toml
├── src/
│   ├── RAIL0.sol                  # the protocol contract
│   └── interfaces/
│       └── IERC20.sol             # IERC20 + IERC20Permit
└── test/
    └── RAIL0.t.sol                # full test suite (lifecycle + meta-tx auth + reentrancy)
```
