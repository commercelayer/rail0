// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20, IERC20Permit } from "./interfaces/IERC20.sol";

/// @title RAIL0 — Peer-to-peer stablecoin payments for commerce
/// @notice Authorize, capture, void, reclaim, and refund stablecoin payments on any
///         EVM-compatible chain. Tokens accepted by a deployment are fixed at
///         construction via an immutable allowlist.
/// @dev    No owner, no admin, no upgradeability. The allowlist is set in the
///         constructor and never changes — new tokens require a new deployment.
contract RAIL0 {
    // ================================================================
    //  Constants
    // ================================================================

    uint256 public constant VERSION = 1;

    /// @dev 100% in basis points.
    uint16 internal constant MAX_FEE_BPS = 10_000;

    /// @dev EIP-712 typehash for the EIP712Domain struct.
    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 typehash for the Payment struct. Field order MUST match the struct layout.
    bytes32 internal constant _PAYMENT_TYPEHASH = keccak256(
        "Payment(address payer,address payee,address token,uint120 maxAmount,uint48 preApprovalExpiry,uint48 authorizationExpiry,uint48 refundExpiry,uint16 feeBps,address feeReceiver)"
    );

    bytes32 internal constant _NAME_HASH = keccak256(bytes("RAIL0"));
    bytes32 internal constant _VERSION_HASH = keccak256(bytes("1"));

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
        address payer;               // buyer — calls authorize, charge, reclaim
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

    /// @notice State per payment ID. Slot is reused, never deleted.
    mapping(bytes32 => PaymentState) internal _state;

    /// @notice Configuration commitment per payment. Set once, never mutated.
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

    error NotPayer();
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

    // ================================================================
    //  Buyer-facing operations
    // ================================================================

    /// @notice Authorize funds: pull `amount` from buyer into escrow.
    /// @param paymentId Caller-supplied unique identifier.
    /// @param p         Full payment configuration. Hash committed on first call.
    /// @param amount    Amount to authorize (must be > 0 and <= p.maxAmount).
    function authorize(bytes32 paymentId, Payment calldata p, uint256 amount) external nonReentrant {
        _authorize(paymentId, p, amount);
    }

    /// @notice `authorize` preceded by an EIP-2612 permit call that grants this contract
    ///         allowance from the buyer. Permit failure is swallowed; if the buyer already
    ///         has standing approval the subsequent transfer still succeeds.
    function permitAndAuthorize(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        try IERC20Permit(p.token).permit(p.payer, address(this), amount, deadline, v, r, s) {} catch {}
        _authorize(paymentId, p, amount);
    }

    /// @notice One-shot: authorize and immediately capture (no hold).
    /// @param paymentId Caller-supplied unique identifier.
    /// @param p         Full payment configuration. Hash committed on first call.
    /// @param amount    Amount to charge (must be > 0 and <= p.maxAmount).
    function charge(bytes32 paymentId, Payment calldata p, uint256 amount) external nonReentrant {
        _charge(paymentId, p, amount);
    }

    /// @notice `charge` preceded by an EIP-2612 permit call that grants this contract
    ///         allowance from the buyer. Permit failure is swallowed; if the buyer already
    ///         has standing approval the subsequent transfer still succeeds.
    function permitAndCharge(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        try IERC20Permit(p.token).permit(p.payer, address(this), amount, deadline, v, r, s) {} catch {}
        _charge(paymentId, p, amount);
    }

    /// @notice Buyer's safety net: reclaim escrowed funds after authorizationExpiry.
    /// @param paymentId Identifier of an existing payment.
    /// @param p         Full payment configuration. Verified against stored hash.
    function reclaim(bytes32 paymentId, Payment calldata p) external nonReentrant {
        if (msg.sender != p.payer) revert NotPayer();
        PaymentState memory s = _loadAndVerify(paymentId, p);
        if (block.timestamp < p.authorizationExpiry) revert AuthorizationNotExpired();
        if (s.capturableAmount == 0) revert NothingToReclaim();

        uint120 amount = s.capturableAmount;
        _state[paymentId].capturableAmount = 0;

        _safeTransfer(p.token, p.payer, amount);

        emit PaymentReclaimed(paymentId, p.payer, p.payee, amount);
    }

    // ================================================================
    //  Merchant-facing operations
    // ================================================================

    /// @notice Capture authorized funds: pay merchant + fee receiver.
    /// @param paymentId Identifier of an existing payment.
    /// @param p         Full payment configuration. Verified against stored hash.
    /// @param amount    Amount to capture (must be > 0 and <= capturableAmount).
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
    /// @param paymentId Identifier of an existing payment.
    /// @param p         Full payment configuration. Verified against stored hash.
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
    /// @param paymentId Identifier of an existing payment.
    /// @param p         Full payment configuration. Verified against stored hash.
    /// @param amount    Amount to refund (must be > 0 and <= refundableAmount).
    function refund(bytes32 paymentId, Payment calldata p, uint256 amount) external nonReentrant {
        _refund(paymentId, p, amount);
    }

    /// @notice `refund` preceded by an EIP-2612 permit call that grants this contract
    ///         allowance from the merchant. Lets merchants refund without maintaining a
    ///         standing approval. Permit failure is swallowed; standing approval still works.
    function permitAndRefund(
        bytes32 paymentId,
        Payment calldata p,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        try IERC20Permit(p.token).permit(p.payee, address(this), amount, deadline, v, r, s) {} catch {}
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

    /// @notice Returns the EIP-712 domain separator for this contract on the current chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ================================================================
    //  Internal helpers
    // ================================================================

    function _authorize(bytes32 paymentId, Payment calldata p, uint256 amount) internal {
        if (msg.sender != p.payer) revert NotPayer();
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
        if (msg.sender != p.payer) revert NotPayer();
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
