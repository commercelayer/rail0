// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20, IERC20Permit } from "./interfaces/IERC20.sol";
import { IEntryPoint, IPaymaster, PackedUserOperation } from "./interfaces/IERC4337.sol";

/// @title RAIL0 — Peer-to-peer stablecoin payments for commerce
/// @notice Authorize, capture, void, reclaim, and refund stablecoin payments on any
///         EVM-compatible chain with an ERC-4337 v0.7 EntryPoint. Bundles a
///         permissionless gas-sponsorship layer scoped to RAIL0 calls: any merchant
///         can pre-fund a gas budget and authorize sponsored transactions for their
///         payments via per-paymentId EIP-712 signatures.
/// @dev    No owner, no admin, no upgradeability. The token allowlist and the
///         EntryPoint reference are immutable, set once in the constructor.
contract RAIL0 is IPaymaster {
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

    // ----- Gas sponsorship (ERC-4337) constants -----

    /// @dev EIP-712 typehash for the merchant's per-paymentId sponsorship signature.
    bytes32 internal constant _SPONSORSHIP_TYPEHASH =
        keccak256("Sponsorship(bytes32 paymentId,bytes32 configHash,uint48 deadline)");

    /// @dev SimpleAccount-style smart-account selector: `execute(address,uint256,bytes)`.
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6;

    /// @dev RAIL0 entrypoint selectors. Sponsorship is restricted to these inner calls.
    bytes4 internal constant SEL_AUTHORIZE = RAIL0.authorize.selector;
    bytes4 internal constant SEL_CHARGE = RAIL0.charge.selector;
    bytes4 internal constant SEL_CAPTURE = RAIL0.capture.selector;
    bytes4 internal constant SEL_VOID = RAIL0.void.selector;
    bytes4 internal constant SEL_RECLAIM = RAIL0.reclaim.selector;
    bytes4 internal constant SEL_REFUND = RAIL0.refund.selector;
    bytes4 internal constant SEL_PERMIT_AUTHORIZE = RAIL0.permitAndAuthorize.selector;
    bytes4 internal constant SEL_PERMIT_CHARGE = RAIL0.permitAndCharge.selector;
    bytes4 internal constant SEL_PERMIT_REFUND = RAIL0.permitAndRefund.selector;

    /// @dev Standard ERC-4337 v0.7 paymasterAndData prefix:
    ///      [paymaster (20)][verificationGasLimit (16)][postOpGasLimit (16)] = 52 bytes.
    uint256 internal constant _PAYMASTER_DATA_OFFSET = 52;

    /// @dev Sponsor data appended after the standard prefix:
    ///      [deadline (6)][signature (65)] = 71 bytes.
    uint256 internal constant _SPONSOR_DATA_LENGTH = 71;

    /// @dev Inner-call layout for any RAIL0 sponsorable entrypoint:
    ///      [selector (4)][paymentId (32)][Payment (288)] = 324 bytes minimum.
    uint256 internal constant _SPONSORED_INNER_MIN_LENGTH = 324;

    /// @dev Offset of the Payment struct within the inner call's data.
    uint256 internal constant _PAYMENT_OFFSET_IN_INNER = 36; // 4 selector + 32 paymentId

    /// @dev Encoded length of the Payment struct (9 value-type fields × 32 bytes).
    uint256 internal constant _PAYMENT_ENCODED_LENGTH = 288;

    // ================================================================
    //  Domain separator (EIP-712)
    // ================================================================

    /// @dev Cached at construction; rebuilt on chain forks where chainid differs.
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    // ================================================================
    //  ERC-4337 EntryPoint
    // ================================================================

    /// @notice The ERC-4337 v0.7 EntryPoint this deployment integrates with.
    ///         Immutable, set in the constructor. Required for gas sponsorship.
    IEntryPoint public immutable ENTRY_POINT;

    // ================================================================
    //  Token allowlist
    // ================================================================

    /// @notice Tokens this deployment accepts. Set in constructor, never mutated.
    mapping(address => bool) private _accepted;

    // ================================================================
    //  Gas sponsorship pool
    // ================================================================

    /// @notice Per-merchant gas budget for sponsoring RAIL0 UserOperations. Each
    ///         merchant deposits native asset (the chain's stablecoin gas token) here;
    ///         the contract forwards the deposit to the EntryPoint and tracks
    ///         per-merchant balances internally.
    mapping(address => uint256) public gasDeposits;

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
    /// @param entryPoint     The canonical ERC-4337 v0.7 EntryPoint on this chain. Required;
    ///                       must be a valid deployed contract for gas sponsorship to work.
    constructor(address[] memory acceptedTokens, address entryPoint) {
        if (entryPoint == address(0)) revert ZeroAddress();
        ENTRY_POINT = IEntryPoint(entryPoint);

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

    event GasDeposit(address indexed merchant, address indexed from, uint256 amount);
    event GasWithdraw(address indexed merchant, address indexed to, uint256 amount);
    event Sponsored(address indexed merchant, bytes32 indexed paymentId, uint256 actualGasCost);

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

    // Gas sponsorship errors
    error OnlyEntryPoint();
    error InvalidPaymasterData();
    error UnsupportedAccountCall();
    error TargetNotSelf();
    error UnauthorizedSelector();
    error InsufficientGasDeposit();
    error InvalidSponsorship();

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
    //  Gas sponsorship (permissionless)
    // ================================================================

    /// @notice Deposit native gas asset to your own merchant gas budget.
    function depositGas() external payable nonReentrant {
        _credit(msg.sender, msg.sender, msg.value);
    }

    /// @notice Deposit native gas asset crediting another merchant's budget.
    function depositGasFor(address merchant) external payable nonReentrant {
        if (merchant == address(0)) revert ZeroAddress();
        _credit(merchant, msg.sender, msg.value);
    }

    /// @notice Withdraw native gas asset from your own merchant gas budget.
    function withdrawGas(address payable to, uint256 amount) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = gasDeposits[msg.sender];
        if (amount > bal) revert InsufficientGasDeposit();
        gasDeposits[msg.sender] = bal - amount;
        ENTRY_POINT.withdrawTo(to, amount);
        emit GasWithdraw(msg.sender, to, amount);
    }

    function _credit(address merchant, address from, uint256 amount) internal {
        gasDeposits[merchant] += amount;
        ENTRY_POINT.depositTo{ value: amount }(address(this));
        emit GasDeposit(merchant, from, amount);
    }

    // ================================================================
    //  ERC-4337 IPaymaster (called by EntryPoint only)
    // ================================================================

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        if (msg.sender != address(ENTRY_POINT)) revert OnlyEntryPoint();
        return _validate(userOp, userOpHash, maxCost);
    }

    function postOp(IPaymaster.PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256)
        external
    {
        if (msg.sender != address(ENTRY_POINT)) revert OnlyEntryPoint();
        _settle(mode, context, actualGasCost);
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

    /// @notice Computes the EIP-712 digest a merchant must sign to authorize sponsorship
    ///         for a specific payment. The signature stays valid for any sponsorable
    ///         RAIL0 UserOp targeting that paymentId until `deadline`.
    function hashSponsorship(bytes32 paymentId, bytes32 configHash, uint48 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(_SPONSORSHIP_TYPEHASH, paymentId, configHash, deadline));
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
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

    /// @dev Computes the same digest as `_hash`, but reads the Payment fields from a
    ///      raw 288-byte slice (as they appear inside an inner RAIL0 call's calldata).
    ///      Equivalent to `_hash` because Solidity ABI-encodes value-type structs as
    ///      a contiguous sequence of 32-byte slots — identical to `abi.encode` of the
    ///      individual fields.
    function _hashFromCalldataPayment(bytes calldata pBytes) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encodePacked(_PAYMENT_TYPEHASH, pBytes));
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    // ================================================================
    //  Sponsorship validation / settlement
    // ================================================================

    function _validate(PackedUserOperation calldata userOp, bytes32, uint256 maxCost)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        bytes calldata pmd = userOp.paymasterAndData;
        if (pmd.length != _PAYMASTER_DATA_OFFSET + _SPONSOR_DATA_LENGTH) revert InvalidPaymasterData();

        uint48 deadline =
            uint48(bytes6(pmd[_PAYMASTER_DATA_OFFSET:_PAYMASTER_DATA_OFFSET + 6]));
        bytes calldata signature =
            pmd[_PAYMASTER_DATA_OFFSET + 6:_PAYMASTER_DATA_OFFSET + _SPONSOR_DATA_LENGTH];

        // Decode the inner call: must be execute(this, 0, RAIL0.X(...)) where X is one
        // of the nine sponsorable entrypoints. Extract paymentId, payee, configHash.
        (bytes32 paymentId, address payee, bytes32 configHash) = _decodeSponsoredCall(userOp.callData);

        // Verify the merchant's EIP-712 sponsorship signature.
        bytes32 sponsorshipDigest = keccak256(
            abi.encodePacked(
                hex"1901",
                _domainSeparator(),
                keccak256(abi.encode(_SPONSORSHIP_TYPEHASH, paymentId, configHash, deadline))
            )
        );
        if (_recoverSigner(sponsorshipDigest, signature) != payee) revert InvalidSponsorship();

        // Pre-deduct maxCost from the merchant's gas budget. postOp refunds the diff.
        uint256 bal = gasDeposits[payee];
        if (bal < maxCost) revert InsufficientGasDeposit();
        gasDeposits[payee] = bal - maxCost;

        context = abi.encode(payee, maxCost, paymentId);
        // sigFailed bit = 0 (we hard-revert above on bad sig); validAfter = 0; validUntil = deadline.
        validationData = uint256(deadline) << 160;
    }

    function _settle(IPaymaster.PostOpMode, bytes calldata context, uint256 actualGasCost) internal {
        (address merchant, uint256 maxCost, bytes32 paymentId) =
            abi.decode(context, (address, uint256, bytes32));
        if (maxCost > actualGasCost) {
            gasDeposits[merchant] += (maxCost - actualGasCost);
        }
        emit Sponsored(merchant, paymentId, actualGasCost);
    }

    /// @dev Parses an outer `execute(address,uint256,bytes)` call from the smart account.
    ///      Reverts unless the inner call targets this contract, uses one of the nine
    ///      RAIL0 entrypoint selectors, and carries (paymentId, Payment, ...) as args.
    function _decodeSponsoredCall(bytes calldata accountCallData)
        internal
        view
        returns (bytes32 paymentId, address payee, bytes32 configHash)
    {
        // Outer execute(...) layout: [4 selector][32 target][32 value][32 dataOffset][32 dataLen][...inner]
        if (accountCallData.length < 4 + 32 * 4) revert UnsupportedAccountCall();
        if (bytes4(accountCallData[0:4]) != EXECUTE_SELECTOR) revert UnsupportedAccountCall();

        address target = address(uint160(uint256(bytes32(accountCallData[4:36]))));
        if (target != address(this)) revert TargetNotSelf();

        uint256 dataOffset = uint256(bytes32(accountCallData[68:100]));
        uint256 lenPos = 4 + dataOffset;
        if (accountCallData.length < lenPos + 32) revert UnsupportedAccountCall();
        uint256 dataLen = uint256(bytes32(accountCallData[lenPos:lenPos + 32]));
        uint256 innerStart = lenPos + 32;
        if (accountCallData.length < innerStart + dataLen) revert UnsupportedAccountCall();
        if (dataLen < _SPONSORED_INNER_MIN_LENGTH) revert UnauthorizedSelector();

        bytes calldata innerData = accountCallData[innerStart:innerStart + dataLen];

        bytes4 innerSel = bytes4(innerData[0:4]);
        if (
            innerSel != SEL_AUTHORIZE && innerSel != SEL_CHARGE && innerSel != SEL_CAPTURE
                && innerSel != SEL_VOID && innerSel != SEL_RECLAIM && innerSel != SEL_REFUND
                && innerSel != SEL_PERMIT_AUTHORIZE && innerSel != SEL_PERMIT_CHARGE
                && innerSel != SEL_PERMIT_REFUND
        ) revert UnauthorizedSelector();

        // paymentId at offset 4..36; Payment struct at offset 36..324; payee is the
        // 2nd field of Payment, so it sits at innerData[68:100] (last 20 bytes of slot).
        paymentId = bytes32(innerData[4:36]);
        payee = address(uint160(uint256(bytes32(innerData[68:100]))));
        configHash = _hashFromCalldataPayment(
            innerData[_PAYMENT_OFFSET_IN_INNER:_PAYMENT_OFFSET_IN_INNER + _PAYMENT_ENCODED_LENGTH]
        );
    }

    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
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
