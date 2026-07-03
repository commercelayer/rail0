// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20, IEIP3009 } from "./interfaces/IERC20.sol";

/// @title RAIL0 — Peer-to-peer stablecoin payments for commerce
/// @notice Authorize, capture, void, release, and refund stablecoin payments on any
///         EVM-compatible chain whose accepted tokens implement EIP-3009
///         (`transferWithAuthorization`). Buyer-funded operations use a single
///         EIP-3009 signature: the buyer signs off-chain and the merchant submits the
///         transaction and pays gas natively, so no token allowance state is touched.
///         Every operation is merchant-submitted, except `release`, which the payer or
///         the payee may submit to return escrowed funds to the buyer.
/// @dev    No owner, no admin, no upgradeability. The token allowlist is set in the
///         constructor and immutable thereafter.
contract RAIL0 {
    // ================================================================
    //  Constants
    // ================================================================

    string public constant VERSION = "1.2.0";

    /// @dev Reason emitted on the `DisputeClosed` event when a dispute is closed
    ///      automatically by a full refund (one that brings `refundableAmount` to 0).
    ///      Lets indexers distinguish a refund-driven close from a buyer withdrawal.
    bytes32 public constant REASON_FULL_REFUND = keccak256("rail0.dispute.full_refund");

    /// @dev EIP-712 typehash for the EIP712Domain struct.
    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 typehash for the Payment struct. Field order MUST match the struct layout.
    bytes32 internal constant _PAYMENT_TYPEHASH = keccak256(
        "Payment(address payer,address payee,address token,uint120 amount,uint48 authorizationExpiry,uint48 refundExpiry)"
    );

    /// @dev Prefixes used to derive EIP-3009 nonces. A per-operation prefix ensures
    ///      signatures cannot be reused across operations.
    ///      Refund nonces also encode the current refundableAmount so each partial
    ///      refund has a unique, deterministic nonce tied to the payment's state at
    ///      signing time — preventing replays and double-spending of the same position.
    bytes32 internal constant _AUTHORIZE_NONCE_PREFIX = keccak256("RAIL0.AUTHORIZE");
    bytes32 internal constant _CHARGE_NONCE_PREFIX    = keccak256("RAIL0.CHARGE");
    bytes32 internal constant _REFUND_NONCE_PREFIX    = keccak256("RAIL0.REFUND");

    bytes32 internal constant _NAME_HASH = keccak256(bytes("RAIL0"));
    bytes32 internal constant _VERSION_HASH = keccak256(bytes(VERSION));

    /// @dev Reentrancy lock states.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ================================================================
    //  Domain separator (EIP-712)
    // ================================================================

    /// @dev Cached at construction; rebuilt on chain forks where chainid differs.
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    // ================================================================
    //  Token allowlist
    // ================================================================

    /// @notice Tokens this deployment accepts. Set in constructor, never mutated.
    mapping(address => bool) private _accepted;

    // ================================================================
    //  Reentrancy lock
    // ================================================================

    uint256 private _reentrancyStatus = _NOT_ENTERED;

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        if (_reentrancyStatus == _ENTERED) revert Reentrancy();
        _reentrancyStatus = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ================================================================
    //  Constructor
    // ================================================================

    /// @param acceptedTokens Token addresses this deployment will accept on `Payment.token`.
    ///                       Each entry must be non-zero and unique. The list is fixed forever.
    ///                       Tokens MUST implement EIP-3009 (`transferWithAuthorization`).
    constructor(address[] memory acceptedTokens) {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();

        uint256 len = acceptedTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address t = acceptedTokens[i];
            if (t == address(0)) revert ZeroAddress();
            if (_accepted[t]) revert DuplicateToken();
            _accepted[t] = true;
            emit TokenAccepted(t);
        }
    }

    // ================================================================
    //  Data model
    // ================================================================

    /// @notice Immutable payment configuration committed at authorize/charge time.
    struct Payment {
        address payer; // buyer — funds are pulled from this address
        address payee; // merchant — calls capture, void, refund
        address token; // EIP-3009-capable ERC-20 (must be in this deployment's allowlist)
        uint120 amount; // exact amount the payer commits to pay
        uint48 authorizationExpiry; // cutoff for capture; release opens after
        uint48 refundExpiry; // cutoff for refund
    }

    /// @notice Mutable payment state, packed in one storage slot (256 bits).
    struct PaymentState {
        bool exists; //   8 bits — set on first authorize/charge
        uint120 capturableAmount; // 120 bits — funds held in escrow
        uint120 refundableAmount; // 120 bits — funds with payee, still refundable
        bool disputed; //   8 bits — buyer has an open dispute (signal only, no fund effect)
    }

    mapping(bytes32 => PaymentState) internal _state;
    mapping(bytes32 => bytes32) internal _configHash;

    // ================================================================
    //  Events
    // ================================================================

    event TokenAccepted(address indexed token);

    event PaymentAuthorized(bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment);
    event PaymentCharged(bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment);
    event PaymentCaptured(bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
    event PaymentVoided(bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
    event PaymentReleased(bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);
    event PaymentRefunded(bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount);

    /// @notice Buyer opened a dispute against a payment. Signal only — no funds move.
    /// @param reason Caller-supplied code (e.g. `keccak256(text)`); meaning lives off-chain.
    event PaymentDisputed(bytes32 indexed paymentId, address indexed payer, address indexed payee, bytes32 reason);

    /// @notice An open dispute was closed. Indexes `payer`/`payee` like every other lifecycle
    ///         event, so closes are filterable by party regardless of who closed them.
    /// @param closedBy The actor: the payer on a withdrawal, or the refund submitter (payee)
    ///         on a full-refund auto-close.
    /// @param reason `REASON_FULL_REFUND` on an auto-close; otherwise a caller-supplied code.
    event DisputeClosed(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, address closedBy, bytes32 reason
    );

    // ================================================================
    //  Errors
    // ================================================================

    error NotPayee();
    error NotPayer();
    error NotPayerOrPayee();
    error AlreadyDisputed();
    error NotDisputed();
    error NothingToDispute();
    error PaymentAlreadyExists();
    error PaymentNotFound();
    error PaymentMismatch();
    error InvalidAmount();
    error InvalidExpiries();
    error AuthorizationExpired();
    error AuthorizationNotExpired();
    error RefundExpired();
    error ZeroAddress();
    error InvalidCaptureAmount();
    error InvalidRefundAmount();
    error NothingToVoid();
    error AlreadyCaptured();
    error NothingToRelease();
    error TokenNotAccepted();
    error DuplicateToken();
    error TransferFailed();
    error Reentrancy();

    // ================================================================
    //  Buyer-funded operations & release
    //  authorize / charge: buyer signs EIP-3009 off-chain, merchant submits.
    //  release: payer or payee submits to return escrow to the buyer.
    // ================================================================

    /// @notice Authorize funds: pull `p.amount` from buyer into escrow.
    /// @dev    The buyer signs an EIP-3009 `TransferWithAuthorization` over the token's
    ///         domain with `from = p.payer`, `to = address(this)`, `value = p.amount`,
    ///         `validAfter = 0`, `validBefore = p.authorizationExpiry`, and
    ///         `nonce = keccak256(_AUTHORIZE_NONCE_PREFIX, paymentId, configHash)`.
    ///         The submission window equals the escrow window — once `authorizationExpiry`
    ///         passes, the sig is dead at the token and the on-chain payment can no longer
    ///         be opened. The nonce derivation binds the signature to specific Payment
    ///         terms — a merchant cannot substitute different terms and reuse the signature.
    ///         Only `p.payee` (the merchant) may submit; the submitter pays gas.
    function authorize(bytes32 paymentId, Payment calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        if (msg.sender != p.payee) revert NotPayee();
        if (_state[paymentId].exists) revert PaymentAlreadyExists();
        _validatePayment(p);

        bytes32 configHash = _hash(p);
        _configHash[paymentId] = configHash;
        _state[paymentId] =
            PaymentState({ exists: true, capturableAmount: p.amount, refundableAmount: 0, disputed: false });

        // EIP-3009 pulls funds — token verifies the buyer's signature. Tampering with
        // any Payment field changes the configHash, which changes the nonce, which
        // makes the recovered signer differ from `p.payer`, causing the token to revert.
        IEIP3009(p.token).transferWithAuthorization(
            p.payer, address(this), p.amount, 0, p.authorizationExpiry,
            _authorizeNonce(paymentId, configHash), v, r, s
        );

        emit PaymentAuthorized(paymentId, p.payer, p.payee, p);
    }

    /// @notice One-shot: authorize and immediately capture (no hold).
    /// @dev    Same EIP-3009 pattern as `authorize` (including `validAfter = 0` and
    ///         `validBefore = p.authorizationExpiry` baked into the buyer's signed
    ///         payload), but the nonce uses `_CHARGE_NONCE_PREFIX` so an authorize-
    ///         signature can't be repurposed for charge (and vice versa). Here
    ///         `authorizationExpiry` is the submission deadline only — there is no
    ///         escrow window because the contract immediately forwards the buyer's
    ///         funds to `payee`. Only `p.payee` (the merchant) may submit.
    function charge(bytes32 paymentId, Payment calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        if (msg.sender != p.payee) revert NotPayee();
        if (_state[paymentId].exists) revert PaymentAlreadyExists();
        _validatePayment(p);

        bytes32 configHash = _hash(p);
        _configHash[paymentId] = configHash;
        _state[paymentId] =
            PaymentState({ exists: true, capturableAmount: 0, refundableAmount: p.amount, disputed: false });

        IEIP3009(p.token).transferWithAuthorization(
            p.payer, address(this), p.amount, 0, p.authorizationExpiry,
            _chargeNonce(paymentId, configHash), v, r, s
        );

        _safeTransfer(p.token, p.payee, p.amount);

        emit PaymentCharged(paymentId, p.payer, p.payee, p);
    }

    /// @notice Release escrowed funds back to the buyer after authorizationExpiry.
    /// @dev    Only the payer or the payee may call — funds always go to `p.payer`
    ///         regardless of which of the two submits, so there is no theft potential.
    ///         A buyer who has been ghosted by the merchant can submit this themselves to
    ///         recover their escrowed funds; the merchant may also submit to settle.
    function release(bytes32 paymentId, Payment calldata p) external nonReentrant {
        if (msg.sender != p.payer && msg.sender != p.payee) revert NotPayerOrPayee();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp < p.authorizationExpiry) revert AuthorizationNotExpired();
        if (s.capturableAmount == 0) revert NothingToRelease();

        uint120 amount = s.capturableAmount;
        _state[paymentId].capturableAmount = 0;

        _safeTransfer(p.token, p.payer, amount);

        emit PaymentReleased(paymentId, p.payer, p.payee, amount);
    }

    // ================================================================
    //  Buyer dispute signal (open / close lifecycle)
    //  No fund effect: opening or closing a dispute never moves, blocks, or
    //  escrows funds. The flag is an on-chain signal that off-chain systems
    //  (indexer, merchant integrations) react to — typically with a refund.
    // ================================================================

    /// @notice Buyer opens a dispute against a payment. No funds move.
    /// @dev    Payer only, only while within the refund window, and only on funds the
    ///         merchant actually holds (`refundableAmount > 0`) — a pure authorization is
    ///         cancelled via `void`, not disputed. Reverts if a dispute is already open;
    ///         reopening after a close is allowed. No external calls, so no `nonReentrant`.
    /// @param reason Caller-supplied code recorded in the event; meaning lives off-chain.
    function dispute(bytes32 paymentId, Payment calldata p, bytes32 reason) external {
        if (msg.sender != p.payer) revert NotPayer();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp >= p.refundExpiry) revert RefundExpired();
        if (s.refundableAmount == 0) revert NothingToDispute();
        if (s.disputed) revert AlreadyDisputed();

        _state[paymentId].disputed = true;

        emit PaymentDisputed(paymentId, p.payer, p.payee, reason);
    }

    /// @notice Buyer withdraws their own open dispute. No funds move.
    /// @dev    Payer only — the payee cannot dismiss a dispute; the merchant's only way to
    ///         close one is to resolve it via a full `refund` (auto-close). No window
    ///         restriction: withdrawing is always benign, so the payer can clear the flag
    ///         even after `refundExpiry`. No external calls, so no `nonReentrant`.
    /// @param reason Caller-supplied code recorded in the event; meaning lives off-chain.
    function closeDispute(bytes32 paymentId, Payment calldata p, bytes32 reason) external {
        if (msg.sender != p.payer) revert NotPayer();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (!s.disputed) revert NotDisputed();

        _state[paymentId].disputed = false;

        emit DisputeClosed(paymentId, p.payer, p.payee, msg.sender, reason);
    }

    // ================================================================
    //  Merchant-initiated operations
    // ================================================================

    /// @notice Capture authorized funds: pay the merchant.
    function capture(bytes32 paymentId, Payment calldata p, uint256 amount) external nonReentrant {
        if (msg.sender != p.payee) revert NotPayee();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp >= p.authorizationExpiry) revert AuthorizationExpired();
        if (amount == 0 || amount > s.capturableAmount) revert InvalidCaptureAmount();

        // Safe cast: amount <= capturableAmount (uint120) checked above.
        uint120 captureAmount120 = uint120(amount); // forge-lint: disable-line(unsafe-typecast)
        _state[paymentId].capturableAmount = s.capturableAmount - captureAmount120;
        _state[paymentId].refundableAmount = s.refundableAmount + captureAmount120;

        _safeTransfer(p.token, p.payee, amount);

        emit PaymentCaptured(paymentId, p.payer, p.payee, amount);
    }

    /// @notice Cancel an authorization, returning held funds to the buyer.
    /// @dev    Only permitted while the authorization is fully intact — no amount
    ///         has been captured. Once any (even partial) capture has occurred,
    ///         `capturableAmount < p.amount` and void reverts with `AlreadyCaptured`;
    ///         the buyer recovers the uncaptured remainder via `release` after
    ///         `authorizationExpiry`. `capturableAmount` only ever decreases (via
    ///         capture) from its initial `p.amount`, so `== p.amount` is an exact
    ///         "nothing captured yet" test — a refund reduces `refundableAmount`,
    ///         never restoring `capturableAmount`.
    function void(bytes32 paymentId, Payment calldata p) external nonReentrant {
        if (msg.sender != p.payee) revert NotPayee();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (s.capturableAmount == 0) revert NothingToVoid();
        if (s.capturableAmount != p.amount) revert AlreadyCaptured();

        uint120 amount = s.capturableAmount;
        _state[paymentId].capturableAmount = 0;

        _safeTransfer(p.token, p.payer, amount);

        emit PaymentVoided(paymentId, p.payer, p.payee, amount);
    }

    /// @notice Refund a previously captured amount from the merchant's wallet.
    /// @dev    Uses EIP-3009 `receiveWithAuthorization` — the payee signs a
    ///         `TransferWithAuthorization` digest off-chain; RAIL0 calls
    ///         `receiveWithAuthorization` to pull funds from the payee directly into
    ///         this contract, then immediately forwards them to the payer. No ERC-20
    ///         allowance (`approve`) is needed.
    ///
    ///         Signature bindings:
    ///           from        = p.payee
    ///           to          = address(this)
    ///           value       = amount
    ///           validAfter  = 0
    ///           validBefore = p.refundExpiry
    ///           nonce       = refundNonce(paymentId, configHash, refundableAmount)
    ///
    ///         The nonce encodes the current `refundableAmount` so each partial refund
    ///         has a unique, deterministic nonce — preventing replay and double-spending
    ///         of the same refund position. Only `p.payee` may submit; funds always reach
    ///         `p.payer`.
    function refund(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        if (msg.sender != p.payee) revert NotPayee();
        PaymentState memory st = _loadAndVerify(paymentId, p);
        if (block.timestamp >= p.refundExpiry) revert RefundExpired();
        if (amount == 0 || amount > st.refundableAmount) revert InvalidRefundAmount();

        // Safe cast: amount <= refundableAmount (uint120) checked above.
        uint120 refundAmount120 = uint120(amount); // forge-lint: disable-line(unsafe-typecast)
        _state[paymentId].refundableAmount = st.refundableAmount - refundAmount120;

        // A full refund (one that zeroes refundableAmount) resolves any open dispute:
        // clear the flag and emit the close event with the reserved reason. Effects only —
        // this sits before the external calls, preserving checks-effects-interactions.
        if (st.disputed && _state[paymentId].refundableAmount == 0) {
            _state[paymentId].disputed = false;
            emit DisputeClosed(paymentId, p.payer, p.payee, msg.sender, REASON_FULL_REFUND);
        }

        // Pull funds from payee using their EIP-3009 signature — no allowance needed.
        // validBefore = p.refundExpiry ensures the signature is dead once the refund window closes.
        IEIP3009(p.token).receiveWithAuthorization(
            p.payee,
            address(this),
            amount,
            0,                   // validAfter: available immediately
            p.refundExpiry,      // validBefore: same as on-chain refund deadline
            _refundNonce(paymentId, _configHash[paymentId], st.refundableAmount),
            v, r, s
        );

        _safeTransfer(p.token, p.payer, amount);

        emit PaymentRefunded(paymentId, p.payer, p.payee, amount);
    }

    // ================================================================
    //  Views
    // ================================================================

    /// @notice Returns true if `token` is in this deployment's allowlist.
    function isAcceptedToken(address token) external view returns (bool) {
        return _accepted[token];
    }

    /// @notice Returns the on-chain state of a payment.
    function getPaymentState(bytes32 paymentId) external view returns (PaymentState memory) {
        return _state[paymentId];
    }

    /// @notice Returns the stored configuration hash for a payment.
    function getConfigHash(bytes32 paymentId) external view returns (bytes32) {
        return _configHash[paymentId];
    }

    /// @notice Computes the canonical EIP-712 digest of a Payment configuration.
    function hashPayment(Payment calldata p) external view returns (bytes32) {
        return _hash(p);
    }

    /// @notice Computes the EIP-3009 nonce the buyer must use when signing a
    ///         `TransferWithAuthorization` for an `authorize` call.
    function authorizeNonce(bytes32 paymentId, bytes32 configHash) external pure returns (bytes32) {
        return _authorizeNonce(paymentId, configHash);
    }

    /// @notice Computes the EIP-3009 nonce the buyer must use when signing a
    ///         `TransferWithAuthorization` for a `charge` call.
    function chargeNonce(bytes32 paymentId, bytes32 configHash) external pure returns (bytes32) {
        return _chargeNonce(paymentId, configHash);
    }

    /// @notice Computes the EIP-3009 nonce the payee must use when signing a
    ///         `TransferWithAuthorization` for a `refund` call.
    /// @param  paymentId    The payment identifier.
    /// @param  configHash   Stored configuration hash (from `getConfigHash`).
    /// @param  refundableAmount Current refundable balance (from `getPaymentState`).
    ///         Including this value makes each partial-refund nonce unique and ties
    ///         the signature to a specific payment state, preventing replay.
    function refundNonce(bytes32 paymentId, bytes32 configHash, uint120 refundableAmount)
        external
        pure
        returns (bytes32)
    {
        return _refundNonce(paymentId, configHash, refundableAmount);
    }

    /// @notice Returns the EIP-712 domain separator for this contract on the current chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ================================================================
    //  Internal helpers
    // ================================================================

    function _authorizeNonce(bytes32 paymentId, bytes32 configHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(_AUTHORIZE_NONCE_PREFIX, paymentId, configHash));
    }

    function _chargeNonce(bytes32 paymentId, bytes32 configHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(_CHARGE_NONCE_PREFIX, paymentId, configHash));
    }

    function _refundNonce(bytes32 paymentId, bytes32 configHash, uint120 refundableAmount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_REFUND_NONCE_PREFIX, paymentId, configHash, refundableAmount));
    }

    function _validatePayment(Payment calldata p) internal view {
        if (p.amount == 0) revert InvalidAmount();
        if (p.authorizationExpiry == 0) revert InvalidExpiries();
        if (p.authorizationExpiry > p.refundExpiry) revert InvalidExpiries();
        if (block.timestamp >= p.authorizationExpiry) revert AuthorizationExpired();
        if (p.payer == address(0) || p.payee == address(0) || p.token == address(0)) {
            revert ZeroAddress();
        }
        if (!_accepted[p.token]) revert TokenNotAccepted();
    }

    function _loadAndVerify(bytes32 paymentId, Payment calldata p) internal view returns (PaymentState memory s) {
        s = _state[paymentId];
        if (!s.exists) revert PaymentNotFound();
        if (_configHash[paymentId] != _hash(p)) revert PaymentMismatch();
    }

    function _hash(Payment calldata p) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _PAYMENT_TYPEHASH,
                p.payer,
                p.payee,
                p.token,
                p.amount,
                p.authorizationExpiry,
                p.refundExpiry
            )
        );
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    function _domainSeparator() internal view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    // ================================================================
    //  ERC-20 transfer helpers
    // ================================================================

    /// @dev Calls `transfer` on `token` and reverts on failure. Accepts both bool-returning
    ///      and non-returning ERC-20 implementations.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
