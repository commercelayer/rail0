# rail0

RAIL0 is a permissionless, peer-to-peer payment protocol for stablecoin commerce. It implements the authorize → capture → refund lifecycle familiar from card networks as a single immutable Solidity contract: buyers and merchants transact directly, the protocol never custodies funds outside the active escrow window, and there is no owner, no admin, no upgradeability, and no protocol fee. The intended environment is the emerging category of **stablecoin-gas L1 chains** — Tempo, Arc, Plasma, Codex — where a stablecoin is the chain's native gas token, finality is sub-second, and the buyer's experience stays single-asset end to end. A companion contract, `RAIL0Sponsor`, provides the standard mechanism for sponsoring buyers' gas — permissionless ERC-4337 paymaster infrastructure that works uniformly across every supported chain. Anyone can be a sponsor: merchants, platforms, payment facilitators, grant programs, or buyers themselves.

## Protocol

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

Each RAIL0 deployment is constructed with a fixed list of accepted ERC-20 token addresses. Calls to `authorize`/`charge` revert with `TokenNotAccepted` if `p.token` is not in the allowlist. The allowlist is set in the constructor and **cannot be modified afterward** — adding a new stablecoin requires a new deployment.

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
- **Test coverage.** A 48-test Foundry suite (`contracts/test/RAIL0.t.sol`) covers the lifecycle, allowlist construction, every revert path, EIP-712 hashing, permit wrappers (success + fallback), reentrancy attempts via a malicious mock token, and USDT-style non-returning tokens. No external audit has been performed.

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

## Gas sponsorship

In RAIL0, a third-party sponsor can pay the buyer's gas. The protocol is agnostic about who that sponsor is — most often it's the merchant (mirroring how card networks shift infrastructure cost off the buyer), but it can equally be a platform aggregating many merchants, a payment facilitator, a chain-grant program subsidizing certain categories of transactions, or the buyer themselves pre-funding their own ops. This is the standard pattern across every chain RAIL0 deploys to, regardless of what fee-payer mechanisms the chain provides natively.

The mechanism is **`RAIL0Sponsor`** (`contracts/src/RAIL0Sponsor.sol`), a permissionless ERC-4337 v0.7 paymaster shipped alongside RAIL0. Any address can deposit native gas into the contract under its own sponsor identity and authorize buyer UserOperations with an EIP-712 signature; the paymaster validates the signature and pays the gas from that sponsor's balance. Because the same contract works on every supported chain, integrators have one mechanism, one signing flow, and one operational model — not a per-chain fork that switches between Tempo's native fee-payer, Arc's paymaster infrastructure, Plasma's quota system, and so on.

This commits the buyer to a smart-account wallet (any ERC-4337-compatible account: SimpleAccount, Safe with the 4337 plugin, Kernel, Biconomy V2, Circle Modular Wallets, etc.) — which is the dominant direction for end-user wallets and the right bet to standardize on.

### Properties

- **No privileged roles.** Same as RAIL0 itself: no owner, no admin, no upgradeability. The EntryPoint and target RAIL0 addresses are immutable, set in the constructor.
- **Permissionless deposits.** Anyone can deposit native gas to their own balance via `deposit()` or to another sponsor's balance via `depositFor(address)`. Each sponsor controls only their own balance.
- **Scoped to RAIL0.** The paymaster verifies on-chain that the sponsored UserOperation is calling one of RAIL0's nine entrypoints via the standard `execute(address,uint256,bytes)` smart-account ABI. A compromised sponsor key can only drain its own deposit on RAIL0 transactions — never on unrelated calls.
- **EIP-712 sponsor signatures.** Each UserOp must carry an EIP-712 signature from the sponsor authorizing that specific `userOpHash`, valid within `[validAfter, validUntil]`. The signed type is `Sponsorship(bytes32 userOpHash,address sponsor,uint48 validUntil,uint48 validAfter)`.
- **Pre-deduct + refund accounting.** `validatePaymasterUserOp` deducts `maxCost` from the sponsor's balance up front; `postOp` refunds the difference between `maxCost` and `actualGasCost`. This serializes concurrent sponsored ops from the same sponsor without requiring a nonce.

### Sponsor flow

1. Sponsor calls `deposit{value: amount}()` (or someone calls `depositFor{value: amount}(sponsor)`). The contract forwards the deposit to the EntryPoint and credits the sponsor's internal balance.
2. A user (typically a smart-account wallet) prepares a `UserOperation` calling RAIL0 via `execute(rail0, 0, encodedRailCall)`.
3. The sponsor's signing service computes the userOpHash, signs the EIP-712 `Sponsorship` digest, and attaches `paymasterAndData` containing `[paymaster][verifGas][postOpGas][sponsor][validUntil][validAfter][signature]`.
4. The bundler submits the UserOp. The EntryPoint calls `validatePaymasterUserOp`, which verifies scope + signature + balance and pre-deducts `maxCost`.
5. Execution runs. The EntryPoint calls `postOp` with the actual gas cost; the sponsor's balance is restored by `(maxCost - actualGasCost)`.
6. The sponsor can withdraw unused balance any time via `withdraw(to, amount)`.

### Account compatibility

The paymaster expects the smart account to expose the standard `execute(address target, uint256 value, bytes data)` selector (`0xb61d27f6`) — used by SimpleAccount, Kernel, Safe with the 4337 plugin, Biconomy V2, and most other modular accounts. Accounts that use non-standard outer ABIs (for example, ERC-7579 batched `execute(bytes32 mode, bytes data)` only) are not sponsorable through this paymaster and would need a different one.

### Sponsor events

```solidity
event Deposit   (address indexed sponsor, address indexed from, uint256 amount);
event Withdraw  (address indexed sponsor, address indexed to,   uint256 amount);
event Sponsored (address indexed sponsor, bytes32 indexed userOpHash, uint256 actualGasCost);
```

## Examples

End-to-end `cast` recipes for every workflow. Examples use `--private-key` for readability — in production, prefer `cast wallet import <name>` once and then `--account <name>` on each command (never put long-lived keys on the command line).

### Setup

Set the addresses and keys you'll reuse:

```sh
export RPC=https://rpc.example.network
export RAIL0=0x...                  # the RAIL0 deployment
export SPONSOR=0x...                # the RAIL0Sponsor deployment (if used)
export TOKEN=0x...                  # an accepted stablecoin
export PAYER=0x...                  # buyer wallet
export PAYEE=0x...                  # merchant wallet
export FEE_RCV=0x...                # fee receiver (or 0x0 if feeBps == 0)
export PAYER_KEY=0x...              # buyer signing key
export PAYEE_KEY=0x...              # merchant signing key
```

The `Payment` struct is a 9-field tuple. Define it once and reuse:

```sh
# (payer, payee, token, maxAmount, preApprovalExpiry, authorizationExpiry, refundExpiry, feeBps, feeReceiver)
export PAYMENT="($PAYER,$PAYEE,$TOKEN,1000000000,1735689600,1736294400,1738972800,250,$FEE_RCV)"
export PAYMENT_TYPE='(address,address,address,uint120,uint48,uint48,uint48,uint16,address)'
export PAYMENT_ID=$(cast keccak "order-12345")
```

### One-time approvals

Buyer grants RAIL0 the right to pull tokens for `authorize` / `charge`:

```sh
cast send $TOKEN "approve(address,uint256)" $RAIL0 $(cast max-uint) \
  --rpc-url $RPC --private-key $PAYER_KEY
```

Merchant grants RAIL0 the right to pull tokens for `refund`:

```sh
cast send $TOKEN "approve(address,uint256)" $RAIL0 $(cast max-uint) \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Authorize → Capture → Refund

**Buyer authorizes** (escrows funds):

```sh
cast send $RAIL0 "authorize(bytes32,$PAYMENT_TYPE,uint256)" \
  $PAYMENT_ID "$PAYMENT" 100000000 \
  --rpc-url $RPC --private-key $PAYER_KEY
```

**Merchant captures** (pulls escrow into payee + fee receiver):

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

**Merchant refunds** (pulls from own wallet back to buyer):

```sh
cast send $RAIL0 "refund(bytes32,$PAYMENT_TYPE,uint256)" \
  $PAYMENT_ID "$PAYMENT" 50000000 \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Charge (one-shot pay-through)

Skip escrow; pay merchant immediately. Refunds remain available until `refundExpiry`.

```sh
cast send $RAIL0 "charge(bytes32,$PAYMENT_TYPE,uint256)" \
  $PAYMENT_ID "$PAYMENT" 100000000 \
  --rpc-url $RPC --private-key $PAYER_KEY
```

### Void (merchant cancels authorization)

Returns all currently-escrowed funds to the buyer. No deadline.

```sh
cast send $RAIL0 "void(bytes32,$PAYMENT_TYPE)" \
  $PAYMENT_ID "$PAYMENT" \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

### Reclaim (buyer's safety net)

After `authorizationExpiry`, if no capture happened, the buyer pulls their escrow back:

```sh
cast send $RAIL0 "reclaim(bytes32,$PAYMENT_TYPE)" \
  $PAYMENT_ID "$PAYMENT" \
  --rpc-url $RPC --private-key $PAYER_KEY
```

### Permit-bundled variants

These need an EIP-2612 `permit` signature on the token. Computing it requires the token's domain separator and the signer's nonce — typically done by a wallet/SDK rather than on the command line. The shape:

```sh
# Sign the permit off-chain (wallet/SDK), then:
cast send $RAIL0 "permitAndAuthorize(bytes32,$PAYMENT_TYPE,uint256,uint256,uint8,bytes32,bytes32)" \
  $PAYMENT_ID "$PAYMENT" 100000000 \
  $DEADLINE $V $R $S \
  --rpc-url $RPC --private-key $PAYER_KEY
```

Same shape for `permitAndCharge` (signed by buyer) and `permitAndRefund` (signed by merchant — owner is `$PAYEE`).

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

Compute the EIP-712 digest the contract uses (matches `getConfigHash` after `authorize`):

```sh
cast call $RAIL0 "hashPayment($PAYMENT_TYPE)(bytes32)" \
  "$PAYMENT" --rpc-url $RPC
```

Domain separator and allowlist check:

```sh
cast call $RAIL0 "DOMAIN_SEPARATOR()(bytes32)" --rpc-url $RPC
cast call $RAIL0 "isAcceptedToken(address)(bool)" $TOKEN --rpc-url $RPC
```

### Gas sponsorship (RAIL0Sponsor)

**Sponsor deposits gas** (forwards to the EntryPoint, credits internal balance):

```sh
# Deposit for self
cast send $SPONSOR "deposit()" --value 0.1ether \
  --rpc-url $RPC --private-key $PAYEE_KEY

# Deposit on behalf of another sponsor
cast send $SPONSOR "depositFor(address)" $PAYEE --value 0.1ether \
  --rpc-url $RPC --private-key $PAYER_KEY
```

**Check sponsor balance:**

```sh
cast call $SPONSOR "deposits(address)(uint256)" $PAYEE --rpc-url $RPC
```

**Withdraw unused balance** (only the sponsor itself can withdraw their own):

```sh
cast send $SPONSOR "withdraw(address,uint256)" $PAYEE 50000000000000000 \
  --rpc-url $RPC --private-key $PAYEE_KEY
```

**Compute the sponsorship digest** for off-chain signing:

```sh
cast call $SPONSOR "hashSponsorship(bytes32,address,uint48,uint48)(bytes32)" \
  $USER_OP_HASH $PAYEE $VALID_UNTIL $VALID_AFTER \
  --rpc-url $RPC
```

The merchant signs this digest, then constructs the UserOp's `paymasterAndData` as `[paymaster (20)][verifGas (16)][postOpGas (16)][sponsor (20)][validUntil (6)][validAfter (6)][signature (65)]` and sends it through a bundler. End-to-end UserOp construction is outside `cast`'s scope — use a 4337 SDK (Pimlico, Stackup, ZeroDev, viem account-abstraction) to assemble and submit.

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
│   ├── RAIL0Sponsor.sol           # ERC-4337 gas sponsorship companion
│   └── interfaces/
│       ├── IERC20.sol             # IERC20 + IERC20Permit
│       └── IERC4337.sol           # IEntryPoint, IPaymaster, PackedUserOperation
└── test/
    ├── RAIL0.t.sol                # 48 tests
    └── RAIL0Sponsor.t.sol         # 25 tests
```
