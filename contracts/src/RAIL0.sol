// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20, IERC20Permit } from "./interfaces/IERC20.sol";

/// @title RAIL0 — Peer-to-peer stablecoin payments for commerce
/// @notice Authorize, capture, void, reclaim, and refund stablecoin payments on any
///         EVM-compatible chain. Buyer-initiated operations (`authorize`, `charge`)
///         use off-chain EIP-712 authorizations: the buyer signs an intent, anyone
///         (typically the merchant) submits the transaction and pays gas natively.
/// @dev    No owner, no admin, no upgradeability. The token allowlist is set in the
///         constructor and immutable thereafter.
contract RAIL0 {
    // ================================================================
    //  Constants
    // ================================================================

    uint256 public constant VERSION = 2;

    /// @dev 100% in basis points.
    uint16 internal constant MAX_FEE_BPS = 10_000;

    /// @dev EIP-712 typehash for the EIP712Domain struct.
    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 typehash for the Payment struct. Field order MUST match the struct layout.
    bytes32 internal constant _PAYMENT_TYPEHASH = keccak256(
        "Payment(address payer,address payee,address token,uint120 maxAmount,uint48 preApprovalExpiry,uint48 authorizationExpiry,uint48 refundExpiry,uint16 feeBps,address feeReceiver)"
    );

    /// @dev Buyer signs this off-chain to authorize a subsequent `authorize` call.
    bytes32 internal constant _AUTHORIZE_INTENT_TYPEHASH =
        keccak256("AuthorizeIntent(bytes32 paymentId,bytes32 configHash,uint256 amount,uint48 deadline)");

    /// @dev Buyer signs this off-chain to authorize a subsequent `charge` call.
    bytes32 internal constant _CHARGE_INTENT_TYPEHASH =
        keccak256("ChargeIntent(bytes32 paymentId,bytes32 configHash,uint256 amount,uint48 deadline)");

    bytes32 internal constant _NAME_HASH = keccak256(bytes("RAIL0"));
    bytes32 internal constant _VERSION_HASH = keccak256(bytes("2"));

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
        address payer;               // buyer — funds are pulled from this address
        address payee;               // merchant — calls capture, void, refund
        address token;               // ERC-20 token (must be in this deployment's allowlist)
        uint120 maxAmount;           // upper bound on what can be authorized
        uint48  preApprovalExpiry;   // cutoff for authorize/charge
        uint48  authorizationExpiry; // cutoff for capture; reclaim opens after
        uint48  refundExpiry;        // cutoff for refund
        uint16  feeBps;              // fee in basis points (0–10000)
        address feeReceiver;         // recipient of fee on each capture (address(0) if no fee)
    }

    /// @notice Mutable payment state, packed in one storage slot (248 bits).
    struct PaymentState {
        bool    exists;            //   8 bits — set on first authorize/charge
        uint120 capturableAmount;  // 120 bits — funds held in escrow
        uint120 refundableAmount;  // 120 bits — funds with payee, still refundable
    }

    mapping(bytes32 => PaymentState) internal _state;
    mapping(bytes32 => bytes32) internal _configHash;

    // ================================================================
    //  Events
    // ================================================================

    event TokenAccepted(address indexed token);

    event PaymentAuthorized(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment, uint256 amount
    );
    event PaymentCharged(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, Payment payment, uint256 amount
    );
    event PaymentCaptured(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount
    );
    event PaymentVoided(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount
    );
    event PaymentReclaimed(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount
    );
    event PaymentRefunded(
        bytes32 indexed paymentId, address indexed payer, address indexed payee, uint256 amount
    );

    // ================================================================
    //  Errors
    // ================================================================

    error NotPayee();
    error PaymentAlreadyExists();
    error PaymentNotFound();
    error PaymentMismatch();
    error InvalidAmount();
    error AmountTooLarge();
    error InvalidExpiries();
    error PreApprovalExpired();
    error AuthorizationExpired();
    error AuthorizationNotExpired();
    error RefundExpired();
    error FeeBpsTooHigh();
    error ZeroFeeReceiver();
    error FeeReceiverIsParty();
    error ZeroAddress();
    error InvalidCaptureAmount();
    error InvalidRefundAmount();
    error NothingToVoid();
    error NothingToReclaim();
    error TokenNotAccepted();
    error DuplicateToken();
    error TransferFailed();
    error Reentrancy();
    error InvalidAuthorization();
    error AuthorizationDeadlineExpired();

    // ================================================================
    //  Buyer-initiated operations (off-chain auth, anyone submits)
    // ================================================================

    /// @notice Authorize funds: pull `amount` from buyer into escrow.
    /// @dev    The buyer signs `AuthorizeIntent(paymentId, configHash, amount, deadline)`
    ///         off-chain. Anyone — typically the merchant — submits this transaction and
    ///         pays gas. The buyer's wallet never broadcasts a transaction.
    function authorize(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint48 deadline,
        bytes calldata buyerSig
    ) external nonReentrant {
        _verifyIntent(_AUTHORIZE_INTENT_TYPEHASH, paymentId, p, amount, deadline, buyerSig);
        _authorize(paymentId, p, amount);
    }

    /// @notice `authorize` preceded by an EIP-2612 token permit grant from the buyer.
    /// @dev    Buyer signs both the `AuthorizeIntent` and the token permit; merchant submits.
    ///         The permit call is wrapped in `try/catch` and degrades gracefully on tokens
    ///         without EIP-2612 or when the buyer already has standing approval.
    function permitAndAuthorize(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint48 deadline,
        bytes calldata buyerSig,
        uint256 permitDeadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external nonReentrant {
        _verifyIntent(_AUTHORIZE_INTENT_TYPEHASH, paymentId, p, amount, deadline, buyerSig);
        try IERC20Permit(p.token).permit(p.payer, address(this), amount, permitDeadline, permitV, permitR, permitS) {} catch {}
        _authorize(paymentId, p, amount);
    }

    /// @notice One-shot: authorize and immediately capture (no hold).
    /// @dev    Buyer signs `ChargeIntent(paymentId, configHash, amount, deadline)`.
    function charge(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint48 deadline,
        bytes calldata buyerSig
    ) external nonReentrant {
        _verifyIntent(_CHARGE_INTENT_TYPEHASH, paymentId, p, amount, deadline, buyerSig);
        _charge(paymentId, p, amount);
    }

    /// @notice `charge` preceded by an EIP-2612 token permit grant from the buyer.
    function permitAndCharge(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint48 deadline,
        bytes calldata buyerSig,
        uint256 permitDeadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external nonReentrant {
        _verifyIntent(_CHARGE_INTENT_TYPEHASH, paymentId, p, amount, deadline, buyerSig);
        try IERC20Permit(p.token).permit(p.payer, address(this), amount, permitDeadline, permitV, permitR, permitS) {} catch {}
        _charge(paymentId, p, amount);
    }

    /// @notice Buyer's safety net: reclaim escrowed funds after authorizationExpiry.
    /// @dev    Anyone can call this — funds always go to `p.payer` regardless of submitter,
    ///         so there is no theft potential. A buyer who has been ghosted by the merchant
    ///         doesn't need to hold gas; a relayer or watchdog service can submit the
    ///         reclaim on their behalf.
    function reclaim(bytes32 paymentId, Payment calldata p) external nonReentrant {
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp < p.authorizationExpiry) revert AuthorizationNotExpired();
        if (s.capturableAmount == 0) revert NothingToReclaim();

        uint120 amount = s.capturableAmount;
        _state[paymentId].capturableAmount = 0;

        _safeTransfer(p.token, p.payer, amount);

        emit PaymentReclaimed(paymentId, p.payer, p.payee, amount);
    }

    // ================================================================
    //  Merchant-initiated operations
    // ================================================================

    /// @notice Capture authorized funds: pay merchant + fee receiver.
    function capture(bytes32 paymentId, Payment calldata p, uint256 amount) external nonReentrant {
        if (msg.sender != p.payee) revert NotPayee();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp >= p.authorizationExpiry) revert AuthorizationExpired();
        if (amount == 0 || amount > s.capturableAmount) revert InvalidCaptureAmount();

        // Safe cast: amount <= capturableAmount (uint120) checked above; sum <= maxAmount <= uint120.
        uint120 captureAmount120 = uint120(amount); // forge-lint: disable-line(unsafe-typecast)
        _state[paymentId].capturableAmount = s.capturableAmount - captureAmount120;
        _state[paymentId].refundableAmount = s.refundableAmount + captureAmount120;

        _distribute(p, amount);

        emit PaymentCaptured(paymentId, p.payer, p.payee, amount);
    }

    /// @notice Cancel an authorization, returning held funds to the buyer.
    function void(bytes32 paymentId, Payment calldata p) external nonReentrant {
        if (msg.sender != p.payee) revert NotPayee();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (s.capturableAmount == 0) revert NothingToVoid();

        uint120 amount = s.capturableAmount;
        _state[paymentId].capturableAmount = 0;

        _safeTransfer(p.token, p.payer, amount);

        emit PaymentVoided(paymentId, p.payer, p.payee, amount);
    }

    /// @notice Refund a previously captured amount from the merchant's wallet.
    /// @dev    Captured funds live in the payee's wallet, not in this contract. Refund
    ///         pulls them back via `transferFrom`, so the payee MUST maintain an ERC-20
    ///         allowance to this contract on `p.token` of at least `amount`. Use
    ///         `permitAndRefund` to provide the allowance via signature in the same tx.
    function refund(bytes32 paymentId, Payment calldata p, uint256 amount) external nonReentrant {
        _refund(paymentId, p, amount);
    }

    /// @notice `refund` preceded by an EIP-2612 token permit grant from the merchant.
    function permitAndRefund(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint256 permitDeadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external nonReentrant {
        try IERC20Permit(p.token).permit(p.payee, address(this), amount, permitDeadline, permitV, permitR, permitS) {} catch {}
        _refund(paymentId, p, amount);
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

    /// @notice Computes the EIP-712 digest the buyer signs to authorize an `authorize` call.
    function hashAuthorizeIntent(bytes32 paymentId, bytes32 configHash, uint256 amount, uint48 deadline)
        external
        view
        returns (bytes32)
    {
        return _intentDigest(_AUTHORIZE_INTENT_TYPEHASH, paymentId, configHash, amount, deadline);
    }

    /// @notice Computes the EIP-712 digest the buyer signs to authorize a `charge` call.
    function hashChargeIntent(bytes32 paymentId, bytes32 configHash, uint256 amount, uint48 deadline)
        external
        view
        returns (bytes32)
    {
        return _intentDigest(_CHARGE_INTENT_TYPEHASH, paymentId, configHash, amount, deadline);
    }

    /// @notice Returns the EIP-712 domain separator for this contract on the current chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ================================================================
    //  Internal helpers — intent verification
    // ================================================================

    function _verifyIntent(
        bytes32 typehash,
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint48 deadline,
        bytes calldata sig
    ) internal view {
        if (block.timestamp > deadline) revert AuthorizationDeadlineExpired();
        bytes32 configHash = _hash(p);
        bytes32 digest = _intentDigest(typehash, paymentId, configHash, amount, deadline);
        if (_recoverSigner(digest, sig) != p.payer) revert InvalidAuthorization();
    }

    function _intentDigest(
        bytes32 typehash,
        bytes32 paymentId,
        bytes32 configHash,
        uint256 amount,
        uint48 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(typehash, paymentId, configHash, amount, deadline));
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }

    // ================================================================
    //  Internal helpers — lifecycle
    // ================================================================

    function _authorize(bytes32 paymentId, Payment calldata p, uint256 amount) internal {
        if (_state[paymentId].exists) revert PaymentAlreadyExists();
        _validatePayment(p, amount);

        _configHash[paymentId] = _hash(p);
        // Safe cast: _validatePayment enforces amount <= maxAmount <= type(uint120).max.
        uint120 amount120 = uint120(amount); // forge-lint: disable-line(unsafe-typecast)
        _state[paymentId] = PaymentState({
            exists: true,
            capturableAmount: amount120,
            refundableAmount: 0
        });

        _safeTransferFrom(p.token, p.payer, address(this), amount);

        emit PaymentAuthorized(paymentId, p.payer, p.payee, p, amount);
    }

    function _charge(bytes32 paymentId, Payment calldata p, uint256 amount) internal {
        if (_state[paymentId].exists) revert PaymentAlreadyExists();
        _validatePayment(p, amount);

        _configHash[paymentId] = _hash(p);
        // Safe cast: _validatePayment enforces amount <= maxAmount <= type(uint120).max.
        uint120 amount120 = uint120(amount); // forge-lint: disable-line(unsafe-typecast)
        _state[paymentId] = PaymentState({
            exists: true,
            capturableAmount: 0,
            refundableAmount: amount120
        });

        _safeTransferFrom(p.token, p.payer, address(this), amount);
        _distribute(p, amount);

        emit PaymentCharged(paymentId, p.payer, p.payee, p, amount);
    }

    function _refund(bytes32 paymentId, Payment calldata p, uint256 amount) internal {
        if (msg.sender != p.payee) revert NotPayee();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp >= p.refundExpiry) revert RefundExpired();
        if (amount == 0 || amount > s.refundableAmount) revert InvalidRefundAmount();

        // Safe cast: amount <= refundableAmount (uint120) checked above.
        uint120 refundAmount120 = uint120(amount); // forge-lint: disable-line(unsafe-typecast)
        _state[paymentId].refundableAmount = s.refundableAmount - refundAmount120;

        _safeTransferFrom(p.token, p.payee, p.payer, amount);

        emit PaymentRefunded(paymentId, p.payer, p.payee, amount);
    }

    function _validatePayment(Payment calldata p, uint256 amount) internal view {
        if (amount == 0 || amount > p.maxAmount) revert InvalidAmount();
        if (p.maxAmount > type(uint120).max) revert AmountTooLarge();
        if (p.preApprovalExpiry == 0) revert InvalidExpiries();
        if (p.preApprovalExpiry > p.authorizationExpiry) revert InvalidExpiries();
        if (p.authorizationExpiry > p.refundExpiry) revert InvalidExpiries();
        if (block.timestamp >= p.preApprovalExpiry) revert PreApprovalExpired();
        if (p.feeBps > MAX_FEE_BPS) revert FeeBpsTooHigh();
        if (p.feeBps > 0) {
            if (p.feeReceiver == address(0)) revert ZeroFeeReceiver();
            if (p.feeReceiver == p.payer || p.feeReceiver == p.payee) revert FeeReceiverIsParty();
        }
        if (p.payer == address(0) || p.payee == address(0) || p.token == address(0)) {
            revert ZeroAddress();
        }
        if (!_accepted[p.token]) revert TokenNotAccepted();
    }

    function _loadAndVerify(bytes32 paymentId, Payment calldata p)
        internal
        view
        returns (PaymentState memory s)
    {
        s = _state[paymentId];
        if (!s.exists) revert PaymentNotFound();
        if (_configHash[paymentId] != _hash(p)) revert PaymentMismatch();
    }

    function _distribute(Payment calldata p, uint256 amount) internal {
        uint256 fee = (amount * p.feeBps) / MAX_FEE_BPS;
        if (fee > 0) {
            _safeTransfer(p.token, p.feeReceiver, fee);
        }
        if (amount > fee) {
            _safeTransfer(p.token, p.payee, amount - fee);
        }
    }

    function _hash(Payment calldata p) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _PAYMENT_TYPEHASH,
                p.payer,
                p.payee,
                p.token,
                p.maxAmount,
                p.preApprovalExpiry,
                p.authorizationExpiry,
                p.refundExpiry,
                p.feeBps,
                p.feeReceiver
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
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
    }

    // ================================================================
    //  ERC-20 transfer helpers
    // ================================================================

    /// @dev Calls `transfer` on `token` and reverts on failure. Accepts both bool-returning
    ///      and non-returning ERC-20 implementations.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Calls `transferFrom` on `token` and reverts on failure. Accepts both
    ///      bool-returning and non-returning ERC-20 implementations.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
