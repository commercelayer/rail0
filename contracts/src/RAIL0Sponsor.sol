// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IEntryPoint, IPaymaster, PackedUserOperation } from "./interfaces/IERC4337.sol";
import { RAIL0 } from "./RAIL0.sol";

/// @title RAIL0Sponsor — Permissionless ERC-4337 paymaster scoped to one RAIL0 deployment
/// @notice Anyone can deposit native gas and sponsor RAIL0 transactions for any user.
///         Sponsorship is authorized per UserOperation by an EIP-712 signature from the
///         sponsor. The contract enforces on-chain that sponsored UserOps target RAIL0
///         and call one of its nine entrypoints — sponsors cannot be tricked into
///         paying gas for unrelated transactions, even if their signing key leaks.
/// @dev    No owner, no admin, no upgradeability. The EntryPoint and RAIL0 addresses
///         are immutable; sponsors manage their own deposits.
contract RAIL0Sponsor is IPaymaster {
    // ================================================================
    //  Constants
    // ================================================================

    uint256 public constant VERSION = 1;

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

    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant _SPONSORSHIP_TYPEHASH =
        keccak256("Sponsorship(bytes32 userOpHash,address sponsor,uint48 validUntil,uint48 validAfter)");

    bytes32 internal constant _NAME_HASH = keccak256(bytes("RAIL0Sponsor"));
    bytes32 internal constant _VERSION_HASH = keccak256(bytes("1"));

    /// @dev Standard ERC-4337 paymasterAndData prefix size:
    ///      [paymaster (20)][verificationGasLimit (16)][postOpGasLimit (16)] = 52 bytes.
    uint256 internal constant _PAYMASTER_DATA_OFFSET = 52;

    /// @dev Sponsor data appended after the standard prefix:
    ///      [sponsor (20)][validUntil (6)][validAfter (6)][signature (65)] = 97 bytes.
    uint256 internal constant _SPONSOR_DATA_LENGTH = 97;

    // ================================================================
    //  Immutable configuration
    // ================================================================

    IEntryPoint public immutable ENTRY_POINT;
    address public immutable RAIL0_ADDRESS;

    /// @dev Cached at construction; rebuilt on chain forks where chainid differs.
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    // ================================================================
    //  Storage
    // ================================================================

    /// @notice Per-sponsor balance held at this paymaster. Each sponsor's deposit is
    ///         forwarded to the EntryPoint and tracked here for accounting.
    mapping(address => uint256) public deposits;

    // ================================================================
    //  Events
    // ================================================================

    event Deposit(address indexed sponsor, address indexed from, uint256 amount);
    event Withdraw(address indexed sponsor, address indexed to, uint256 amount);
    event Sponsored(address indexed sponsor, bytes32 indexed userOpHash, uint256 actualGasCost);

    // ================================================================
    //  Errors
    // ================================================================

    error OnlyEntryPoint();
    error ZeroAddress();
    error InsufficientDeposit();
    error InvalidPaymasterData();
    error UnsupportedAccountCall();
    error TargetNotRAIL0();
    error UnauthorizedSelector();

    // ================================================================
    //  Constructor
    // ================================================================

    /// @param entryPoint The canonical ERC-4337 EntryPoint on this chain.
    /// @param rail0      The RAIL0 deployment whose calls this sponsor will pay gas for.
    constructor(address entryPoint, address rail0) {
        if (entryPoint == address(0) || rail0 == address(0)) revert ZeroAddress();
        ENTRY_POINT = IEntryPoint(entryPoint);
        RAIL0_ADDRESS = rail0;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ================================================================
    //  Sponsor balance management (permissionless)
    // ================================================================

    /// @notice Deposit native gas to sponsor your own RAIL0 UserOps.
    function deposit() external payable {
        _credit(msg.sender, msg.sender, msg.value);
    }

    /// @notice Deposit native gas crediting another sponsor's balance.
    function depositFor(address sponsor) external payable {
        if (sponsor == address(0)) revert ZeroAddress();
        _credit(sponsor, msg.sender, msg.value);
    }

    /// @notice Withdraw native gas from your own sponsor balance.
    function withdraw(address payable to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = deposits[msg.sender];
        if (amount > bal) revert InsufficientDeposit();
        deposits[msg.sender] = bal - amount;
        ENTRY_POINT.withdrawTo(to, amount);
        emit Withdraw(msg.sender, to, amount);
    }

    function _credit(address sponsor, address from, uint256 amount) internal {
        deposits[sponsor] += amount;
        ENTRY_POINT.depositTo{ value: amount }(address(this));
        emit Deposit(sponsor, from, amount);
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

    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256)
        external
    {
        if (msg.sender != address(ENTRY_POINT)) revert OnlyEntryPoint();
        _settle(mode, context, actualGasCost);
    }

    // ================================================================
    //  Internal logic
    // ================================================================

    function _validate(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        bytes calldata pmd = userOp.paymasterAndData;
        if (pmd.length != _PAYMASTER_DATA_OFFSET + _SPONSOR_DATA_LENGTH) revert InvalidPaymasterData();

        address sponsor = address(bytes20(pmd[_PAYMASTER_DATA_OFFSET:_PAYMASTER_DATA_OFFSET + 20]));
        uint48 validUntil = uint48(bytes6(pmd[_PAYMASTER_DATA_OFFSET + 20:_PAYMASTER_DATA_OFFSET + 26]));
        uint48 validAfter = uint48(bytes6(pmd[_PAYMASTER_DATA_OFFSET + 26:_PAYMASTER_DATA_OFFSET + 32]));
        bytes calldata signature = pmd[_PAYMASTER_DATA_OFFSET + 32:_PAYMASTER_DATA_OFFSET + _SPONSOR_DATA_LENGTH];

        // Scope check: the UserOp must call RAIL0 via the standard execute(address,uint256,bytes)
        // smart-account ABI, with one of RAIL0's nine entrypoints as the inner selector.
        _verifyTargetsRAIL0(userOp.callData);

        // Pre-deduct maxCost from sponsor balance to serialize concurrent ops.
        // postOp refunds (maxCost - actualGasCost). Underflow reverts naturally.
        uint256 bal = deposits[sponsor];
        if (bal < maxCost) revert InsufficientDeposit();
        deposits[sponsor] = bal - maxCost;

        // Verify the sponsor's EIP-712 signature.
        bytes32 structHash =
            keccak256(abi.encode(_SPONSORSHIP_TYPEHASH, userOpHash, sponsor, validUntil, validAfter));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
        bool sigValid = _recoverSigner(digest, signature) == sponsor;

        context = abi.encode(sponsor, maxCost, userOpHash);
        validationData = _packValidationData(!sigValid, validUntil, validAfter);
    }

    function _settle(PostOpMode, bytes calldata context, uint256 actualGasCost) internal {
        (address sponsor, uint256 maxCost, bytes32 userOpHash) =
            abi.decode(context, (address, uint256, bytes32));

        // Refund the difference. actualGasCost <= maxCost is guaranteed by EntryPoint accounting.
        if (maxCost > actualGasCost) {
            deposits[sponsor] += (maxCost - actualGasCost);
        }
        emit Sponsored(sponsor, userOpHash, actualGasCost);
    }

    // ================================================================
    //  Scope enforcement
    // ================================================================

    /// @dev Parses an outer `execute(address,uint256,bytes)` call from a SimpleAccount-style
    ///      smart account. Reverts unless the inner call targets RAIL0 and uses one of its
    ///      nine entrypoint selectors. Accounts using non-standard execute ABIs are not
    ///      sponsorable through this paymaster.
    // RAIL0 is the brand acronym, kept uppercase like ERC20 / USDC.
    // forge-lint: disable-next-line(mixed-case-function)
    function _verifyTargetsRAIL0(bytes calldata accountCallData) internal view {
        // Layout: [4 selector][32 target][32 value][32 data offset][32 data length][data...]
        if (accountCallData.length < 4 + 32 + 32 + 32 + 32) revert UnsupportedAccountCall();
        if (bytes4(accountCallData[0:4]) != EXECUTE_SELECTOR) revert UnsupportedAccountCall();

        address target = address(uint160(uint256(bytes32(accountCallData[4:36]))));
        if (target != RAIL0_ADDRESS) revert TargetNotRAIL0();

        // The bytes data offset is relative to the start of the args (post-selector).
        uint256 dataOffset = uint256(bytes32(accountCallData[68:100]));
        uint256 lenPos = 4 + dataOffset;
        if (accountCallData.length < lenPos + 32 + 4) revert UnsupportedAccountCall();

        uint256 dataLen = uint256(bytes32(accountCallData[lenPos:lenPos + 32]));
        if (dataLen < 4) revert UnauthorizedSelector();

        bytes4 innerSel = bytes4(accountCallData[lenPos + 32:lenPos + 36]);
        if (
            innerSel != SEL_AUTHORIZE && innerSel != SEL_CHARGE && innerSel != SEL_CAPTURE
                && innerSel != SEL_VOID && innerSel != SEL_RECLAIM && innerSel != SEL_REFUND
                && innerSel != SEL_PERMIT_AUTHORIZE && innerSel != SEL_PERMIT_CHARGE
                && innerSel != SEL_PERMIT_REFUND
        ) revert UnauthorizedSelector();
    }

    // ================================================================
    //  EIP-712
    // ================================================================

    /// @notice Computes the EIP-712 digest a sponsor must sign to authorize a UserOp.
    function hashSponsorship(bytes32 userOpHash, address sponsor, uint48 validUntil, uint48 validAfter)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(_SPONSORSHIP_TYPEHASH, userOpHash, sponsor, validUntil, validAfter));
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    /// @notice Returns the EIP-712 domain separator for this contract on the current chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
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
    //  Helpers
    // ================================================================

    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }

    /// @dev ERC-4337 v0.7 validationData encoding:
    ///      bit 0: 1 if signature failed
    ///      bits 1..160: aggregator (always 0 here)
    ///      bits 160..208: validUntil (uint48)
    ///      bits 208..256: validAfter (uint48)
    function _packValidationData(bool sigFailed, uint48 validUntil, uint48 validAfter)
        internal
        pure
        returns (uint256)
    {
        return (sigFailed ? 1 : 0) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }
}
