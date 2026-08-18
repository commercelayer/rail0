// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { RAIL0 } from "../src/RAIL0.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";

// ================================================================
//  Mock tokens
// ================================================================

/// Standard ERC-20 with EIP-3009 `transferWithAuthorization` and
/// `receiveWithAuthorization`, each verified against its OWN typehash — mirroring
/// FiatTokenV2 (USDC), where the two are distinct despite the identical field list.
contract MockERC20 {
    // Lowercase to match the ERC-20 standard's `name()` / `version()` getters.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "Mock Stablecoin";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant version = "1";

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp > validAfter, "EIP3009: not yet valid");
        require(block.timestamp < validBefore, "EIP3009: expired");
        require(!authorizationState[from][nonce], "EIP3009: nonce used");

        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == from, "EIP3009: bad sig");

        authorizationState[from][nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;

        emit AuthorizationUsed(from, nonce);
    }

    /// @dev EIP-3009 receiveWithAuthorization: caller must be `to`.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(msg.sender == to, "EIP3009: caller must be receiver");
        require(block.timestamp > validAfter, "EIP3009: not yet valid");
        require(block.timestamp < validBefore, "EIP3009: expired");
        require(!authorizationState[from][nonce], "EIP3009: nonce used");

        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == from, "EIP3009: bad sig");

        authorizationState[from][nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;

        emit AuthorizationUsed(from, nonce);
    }
}

/// Token with working EIP-3009 but whose `transfer` returns false. Used to verify
/// that `_safeTransfer` reverts with `TransferFailed` on bool=false return.
/// Token that blocks transfers to ONE address, the way an issuer blacklist does
/// (USDC's `blacklist(addr)`). Distinct from MockTransferFails, which blocks every
/// transfer: the point here is that the payee side keeps working while the payer side
/// does not, which is what makes the escrow reachable only via capture. See
/// test_FrozenBuyer_EscrowIsStuckAfterExpiry.
contract MockBlacklistsAddress is MockERC20 {
    address public blocked;

    function blacklist(address a) external {
        blocked = a;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (to == blocked) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockTransferFails is MockERC20 {
    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// Token whose receiveWithAuthorization calls back into RAIL0 (reentrancy attempt).
contract MockReentrant {
    bool public reenterAttempted;
    bool public reenterSucceeded;
    bytes public reenterRevertData; // revert data of the inner call when it failed
    address public rail0;
    bytes public payload;

    function arm(address _rail0, bytes calldata _payload) external {
        rail0 = _rail0;
        payload = _payload;
    }

    function receiveWithAuthorization(address, address, uint256, uint256, uint256, bytes32, uint8, bytes32, bytes32)
        external
    {
        if (rail0 != address(0) && payload.length > 0) {
            reenterAttempted = true;
            (bool ok, bytes memory ret) = rail0.call(payload);
            reenterSucceeded = ok;
            if (!ok) reenterRevertData = ret;
        }
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

// ================================================================
//  Test contract
// ================================================================

contract RAIL0Test is Test {
    RAIL0 internal rail0;
    MockERC20 internal token;

    address internal payer;
    uint256 internal payerKey;
    address internal payee;
    uint256 internal payeeKey;

    uint48 internal authorizationExpiry;
    uint48 internal refundExpiry;

    bytes32 internal constant PAYMENT_ID = keccak256("test-payment-1");
    uint256 internal constant FAR_FUTURE = type(uint256).max;
    bytes32 internal constant DISPUTE_REASON = keccak256("item-not-received");

    function setUp() public {
        token = new MockERC20();

        address[] memory accepted = new address[](1);
        accepted[0] = address(token);
        rail0 = new RAIL0(accepted);

        (payer, payerKey) = makeAddrAndKey("payer");
        (payee, payeeKey) = makeAddrAndKey("payee");

        vm.warp(1_700_000_000);
        authorizationExpiry = uint48(block.timestamp + 7 days);
        refundExpiry = uint48(block.timestamp + 30 days);

        token.mint(payer, 10_000e6);
    }

    // ============================================================
    //  Helpers
    // ============================================================

    function _payment() internal view returns (RAIL0.Payment memory) {
        return RAIL0.Payment({
            payer: payer,
            payee: payee,
            token: address(token),
            amount: 100e6,
            authorizationExpiry: authorizationExpiry,
            refundExpiry: refundExpiry
        });
    }

    /// Sign an EIP-3009 ReceiveWithAuthorization for the given token, with the
    /// nonce derived as RAIL0 would expect. Every RAIL0 operation that spends a
    /// signature (authorize, charge, refund) goes through `receiveWithAuthorization`,
    /// so this is the only digest the suite ever signs against a well-behaved token.
    function _signReceive3009(
        uint256 ownerKey,
        MockERC20 t,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(t.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", t.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    /// Submit `authorize` as the merchant on behalf of the payer.
    function _authorize(bytes32 paymentId, RAIL0.Payment memory p) internal {
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(paymentId, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);
        vm.prank(payee);
        rail0.authorize(paymentId, p, v, r, s);
    }

    function _charge(bytes32 paymentId, RAIL0.Payment memory p) internal {
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(paymentId, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);
        vm.prank(payee);
        rail0.charge(paymentId, p, v, r, s);
    }

    /// Submit `refund` — payee signs EIP-3009 off-chain and submits.
    /// Mints only the difference if payee's balance is insufficient.
    function _refund(bytes32 paymentId, RAIL0.Payment memory p, uint256 amount) internal {
        bytes32 configHash = rail0.getConfigHash(paymentId);
        RAIL0.PaymentState memory st0 = rail0.getPaymentState(paymentId);
        bytes32 nonce = rail0.refundNonce(paymentId, configHash, st0.capturableAmount, st0.refundableAmount);
        uint256 bal = token.balanceOf(payee);
        if (bal < amount) token.mint(payee, amount - bal);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), amount, 0, p.refundExpiry, nonce);
        vm.prank(payee);
        rail0.refund(paymentId, p, amount, v, r, s);
    }

    // ============================================================
    //  Lifecycle: authorize
    // ============================================================

    function test_Authorize_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertTrue(s.exists);
        assertEq(s.capturableAmount, 100e6);
        assertEq(s.refundableAmount, 0);
        assertEq(token.balanceOf(address(rail0)), 100e6);
        assertEq(token.balanceOf(payer), 10_000e6 - 100e6);
        assertEq(rail0.getConfigHash(PAYMENT_ID), rail0.hashPayment(p));
    }

    function test_Authorize_RevertsIfNotPayee() public {
        // Only the merchant may submit, even though the buyer's signature is valid.
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.prank(makeAddr("random-relayer"));
        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Authorize_RevertsOnWrongSigner() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        // Sign with payee key instead of payer
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        // Token reverts inside receiveWithAuthorization on bad sig — bubbles through RAIL0.
        vm.expectRevert();
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Authorize_RevertsOnTamperedPayment() public {
        // Two distinct allocations to avoid memory aliasing.
        RAIL0.Payment memory signed = _payment();
        bytes32 signedHash = rail0.hashPayment(signed);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, signedHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), signed.amount, 0, authorizationExpiry, nonce);

        // Submit with tampered Payment — the contract will derive a different nonce
        RAIL0.Payment memory tampered = _payment();
        tampered.amount = 200e6;

        // Pin the failure to the token's signature check: the tampered amount changes
        // the derived nonce, so the recovered signer != payer and the token reverts
        // "EIP3009: bad sig". A bare expectRevert() would also pass if a future RAIL0
        // change reverted earlier — this asserts the tamper actually reaches the token.
        vm.expectRevert(bytes("EIP3009: bad sig"));
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, tampered, v, r, s);
    }

    function test_Authorize_RevertsAfterAuthorizationExpiry() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Authorize_RevertsIfPayerEqualsPayee() public {
        // A self-payment (payer == payee) is rejected in _validatePayment, before
        // any signature check, so a dummy signature is enough. msg.sender must be
        // the payee (== payer here) to pass the NotPayee gate first.
        RAIL0.Payment memory p = _payment();
        p.payee = payer;
        vm.expectRevert(RAIL0.SelfPayment.selector);
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 0, bytes32(0), bytes32(0));
    }

    function test_Charge_RevertsIfPayerEqualsPayee() public {
        RAIL0.Payment memory p = _payment();
        p.payee = payer;
        vm.expectRevert(RAIL0.SelfPayment.selector);
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 0, bytes32(0), bytes32(0));
    }

    function test_Authorize_ChargeNonceDoesNotWorkForAuthorize() public {
        // Buyer signs with the CHARGE nonce — merchant tries to use it for authorize
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 chargeNonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, chargeNonce);

        vm.expectRevert();
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Authorize_RevertsIfPaymentIdReused() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Authorize_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        p.amount = 0;
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), 0, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.InvalidAmount.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Authorize_EmitsEvent() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectEmit(true, true, true, true);
        emit RAIL0.PaymentAuthorized(PAYMENT_ID, payer, payee, p);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    // ============================================================
    //  Lifecycle: charge
    // ============================================================

    function test_Charge_Success() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
        assertEq(token.balanceOf(address(rail0)), 0);
    }

    function test_Charge_AuthorizeNonceDoesNotWorkForCharge() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 authNonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, authNonce);

        vm.expectRevert();
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    function test_Charge_RevertsIfNotPayee() public {
        // Only the merchant may submit, even though the buyer's signature is valid.
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.prank(makeAddr("random-relayer"));
        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    function test_Charge_RevertsOnWrongSigner() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectRevert();
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    function test_Charge_RevertsOnTamperedPayment() public {
        RAIL0.Payment memory signed = _payment();
        bytes32 signedHash = rail0.hashPayment(signed);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, signedHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), signed.amount, 0, authorizationExpiry, nonce);

        RAIL0.Payment memory tampered = _payment();
        tampered.amount = 200e6;

        vm.expectRevert();
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, tampered, v, r, s);
    }

    function test_Charge_RevertsAfterAuthorizationExpiry() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    function test_Charge_RevertsIfPaymentIdReused() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    function test_Charge_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        p.amount = 0;
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), 0, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.InvalidAmount.selector);
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    function test_Charge_EmitsEvent() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectEmit(true, true, true, true);
        emit RAIL0.PaymentCharged(PAYMENT_ID, payer, payee, p);
        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    // ============================================================
    //  Lifecycle: capture
    // ============================================================

    function test_Capture_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
    }

    function test_Capture_Partial_Multiple() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.startPrank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);
        rail0.capture(PAYMENT_ID, p, 20e6);
        rail0.capture(PAYMENT_ID, p, 50e6);
        vm.stopPrank();

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
    }

    function test_Capture_RevertsIfNotPayee() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsAtAuthExpiry() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        vm.prank(payee);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsIfAmountTooLarge() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 100e6 + 1);
    }

    function test_Capture_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 0);
    }

    // ============================================================
    //  Lifecycle: void / release / refund
    // ============================================================

    function test_Void_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Void_RevertsIfNothingToVoid() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p); // capturable = 0

        vm.prank(payee);
        vm.expectRevert(RAIL0.NothingToVoid.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Release_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        uint256 balBefore = token.balanceOf(payer);
        // Buyer recovers their own escrow.
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    /// Pins the partial-capture freeze as it stands, so the accepted trade-off recorded
    /// in the README's security model cannot change silently.
    ///
    /// The two guards are each covered on their own elsewhere. What this pins is their
    /// CONJUNCTION, which is the actual trade-off: after any partial capture there is
    /// no on-chain path to return the remainder before authorizationExpiry, even when
    /// both parties want it returned. void needs the escrow fully intact, release needs
    /// expiry, and refund can only draw on the refundable bucket the capture created —
    /// never on the escrow.
    ///
    /// Capturing 1 unit is enough, which is what makes it a cheap griefing lever: a
    /// merchant can pin the buyer's escrow for the whole window at the cost of settling
    /// one base unit. Deliberately a 1-unit capture here, not a plausible one.
    function test_PartialCapture_FreezesTheRemainderUntilExpiry() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // The minimum that disables void.
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 1);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 100e6 - 1, "escrow should hold the uncaptured remainder");

        // Neither party can return it. Both legs asserted together: either one opening
        // would end the freeze, so a change to either must fail this test.
        vm.prank(payee);
        vm.expectRevert(RAIL0.AlreadyCaptured.selector);
        rail0.void(PAYMENT_ID, p);

        vm.prank(payer);
        vm.expectRevert(RAIL0.AuthorizationNotExpired.selector);
        rail0.release(PAYMENT_ID, p);

        vm.prank(payee);
        vm.expectRevert(RAIL0.AuthorizationNotExpired.selector);
        rail0.release(PAYMENT_ID, p);

        // And the escrow is untouched by the failed attempts.
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6 - 1);

        // The freeze is time-bound, not permanent: release opens at expiry and returns
        // the remainder to the buyer. That exit is the whole reason this is an accepted
        // trade-off rather than a lost-funds bug.
        vm.warp(authorizationExpiry);
        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + (100e6 - 1), "buyer recovers the remainder");
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Release_RevertsBeforeAuthExpiry() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.expectRevert(RAIL0.AuthorizationNotExpired.selector);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Refund_Success() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        uint256 payerBefore = token.balanceOf(payer);
        _refund(PAYMENT_ID, p, 50e6);

        assertEq(token.balanceOf(payer), payerBefore + 50e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 50e6);
    }

    function test_Refund_RevertsIfNotPayee() public {
        // Only the merchant may submit a refund, even with a valid payee signature.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        token.mint(payee, 50e6);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);

        vm.prank(makeAddr("relayer"));
        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);
    }

    function test_Refund_Partial_Multiple() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        // Each partial refund has a unique nonce (encodes the current refundableAmount).
        _refund(PAYMENT_ID, p, 30e6); // nonce includes refundable=100e6
        _refund(PAYMENT_ID, p, 70e6); // nonce includes refundable=70e6

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 0);
    }

    function test_Refund_RevertsAtRefundExpiry() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        token.mint(payee, 50e6);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);

        vm.warp(refundExpiry);
        vm.expectRevert(RAIL0.RefundExpired.selector);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);
    }

    function test_Refund_RevertsOnBadSignature() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        token.mint(payee, 50e6);
        // Sign with payer key instead of payee key → bad sig.
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);

        vm.expectRevert();
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);
    }

    function test_Refund_RevertsOnNonceReplay() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        // First refund succeeds.
        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        token.mint(payee, 100e6);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);

        // Replay with same nonce reverts — token marks nonce as used.
        vm.expectRevert();
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);
    }

    // ============================================================
    //  Lifecycle edge cases (capture/void/release/refund)
    // ============================================================

    function test_Capture_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // Tamper with any field — capture should reject
        p.amount = 9999e6;
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.capture(PAYMENT_ID, p, 50e6);
    }

    function test_Capture_LeavesRemainingCapturable() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 70e6);
        assertEq(s.refundableAmount, 30e6);
    }

    function test_Void_RevertsIfNotPayee() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Void_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Void_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        p.amount = 9999e6;
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Void_RevertsAfterPartialCapture() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        // Once any amount is captured the authorization is no longer intact, so
        // void is forbidden — the merchant can't cancel a partly-captured payment.
        // The buyer recovers the uncaptured 70e6 via release after expiry instead.
        vm.prank(payee);
        vm.expectRevert(RAIL0.AlreadyCaptured.selector);
        rail0.void(PAYMENT_ID, p);

        // State is untouched: escrow and captured funds both remain as they were.
        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 70e6);
        assertEq(s.refundableAmount, 30e6);
    }

    // The uncaptured remainder after a partial capture is recovered via release
    // (once the authorization window closes), since void is no longer available.
    function test_Release_RecoversRemainderAfterPartialCapture() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        vm.warp(authorizationExpiry);
        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 70e6);
        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 30e6);
    }

    function test_Release_RevertsIfNotPayerOrPayee() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        // A totally unrelated address cannot submit — only payer or payee may.
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(RAIL0.NotPayerOrPayee.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_PayeeCanCall() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        // The merchant may also submit the release; funds still go to the buyer.
        vm.prank(payee);
        rail0.release(PAYMENT_ID, p);

        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Release_RevertsIfNothingToRelease() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // Void first → capturable = 0
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.NothingToRelease.selector);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        p.amount = 9999e6;
        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_AfterCharge_RevertsNothingToRelease() public {
        // charge sets capturable = 0; release after authorizationExpiry should revert
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.NothingToRelease.selector);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_AfterFullCapture_RevertsNothingToRelease() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.NothingToRelease.selector);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_AtExactAuthExpiry_Succeeds() public {
        // Boundary: block.timestamp == authorizationExpiry should succeed
        // (the check is `block.timestamp < authorizationExpiry` revert).
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Refund_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 0, 0, p.refundExpiry, nonce);
        vm.expectRevert(RAIL0.InvalidRefundAmount.selector);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 0, v, r, s);
    }

    function test_Refund_RevertsIfAmountExceedsRefundable() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        token.mint(payee, 101e6);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 101e6, 0, p.refundExpiry, nonce);
        vm.expectRevert(RAIL0.InvalidRefundAmount.selector);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 101e6, v, r, s);
    }

    function test_Refund_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        // No payment created — _loadAndVerify reverts with PaymentNotFound.
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, bytes32(0));
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);
    }

    function test_Refund_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        RAIL0.Payment memory bad = p;
        bad.amount = 9999e6;
        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, bad, 50e6, v, r, s);
    }

    function test_Refund_AfterCapture_Workflow() public {
        // authorize → capture → refund: payee signs EIP-3009, pulls from payee wallet
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 100e6);

        uint256 payerBalBefore = token.balanceOf(payer);
        _refund(PAYMENT_ID, p, 40e6);

        assertEq(token.balanceOf(payer), payerBalBefore + 40e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 60e6);
    }

    // ============================================================
    //  Dispute: open (dispute)
    // ============================================================

    function test_Dispute_Success() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p); // refundable = 100e6

        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);

        assertTrue(rail0.getPaymentState(PAYMENT_ID).disputed);
    }

    function test_Dispute_EmitsEvent() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.expectEmit(true, true, true, true);
        emit RAIL0.PaymentDisputed(PAYMENT_ID, payer, payee, DISPUTE_REASON);
        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_Dispute_RevertsIfNotPayer() public {
        // Even the payee (merchant) cannot open a dispute — payer only.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.prank(payee);
        vm.expectRevert(RAIL0.NotPayer.selector);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_Dispute_RevertsAfterRefundExpiry() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.warp(refundExpiry);
        vm.prank(payer);
        vm.expectRevert(RAIL0.RefundExpired.selector);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_Dispute_RevertsIfNothingToDispute() public {
        // Authorize-only payment: refundableAmount == 0, nothing the merchant holds.
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payer);
        vm.expectRevert(RAIL0.NothingToDispute.selector);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_Dispute_RevertsIfAlreadyDisputed() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.startPrank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
        vm.expectRevert(RAIL0.AlreadyDisputed.selector);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
        vm.stopPrank();
    }

    function test_Dispute_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_Dispute_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        p.amount = 9999e6;
        vm.prank(payer);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_Dispute_DoesNotAffectFunds() public {
        // Opening (and later closing) a dispute leaves capturable/refundable untouched.
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 40e6); // capturable = 60e6, refundable = 40e6

        uint256 railBalBefore = token.balanceOf(address(rail0));

        vm.startPrank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
        RAIL0.PaymentState memory sOpen = rail0.getPaymentState(PAYMENT_ID);
        assertEq(sOpen.capturableAmount, 60e6);
        assertEq(sOpen.refundableAmount, 40e6);

        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);
        RAIL0.PaymentState memory sClosed = rail0.getPaymentState(PAYMENT_ID);
        assertEq(sClosed.capturableAmount, 60e6);
        assertEq(sClosed.refundableAmount, 40e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(rail0)), railBalBefore);
    }

    // ============================================================
    //  Dispute: close (closeDispute / withdraw)
    // ============================================================

    function test_CloseDispute_ByPayer() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.startPrank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);

        vm.expectEmit(true, true, true, true);
        emit RAIL0.DisputeClosed(PAYMENT_ID, payer, payee, payer, DISPUTE_REASON);
        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);
        vm.stopPrank();

        assertFalse(rail0.getPaymentState(PAYMENT_ID).disputed);
    }

    function test_CloseDispute_RevertsIfPayee() public {
        // The merchant cannot dismiss a buyer's dispute.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);
        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);

        vm.prank(payee);
        vm.expectRevert(RAIL0.NotPayer.selector);
        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_CloseDispute_RevertsIfStranger() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);
        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RAIL0.NotPayer.selector);
        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_CloseDispute_RevertsIfNotDisputed() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.prank(payer);
        vm.expectRevert(RAIL0.NotDisputed.selector);
        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);
    }

    function test_CloseDispute_AllowedAfterRefundExpiry() public {
        // The terminal-hanging case: an open dispute past refundExpiry can still be
        // withdrawn by the payer at any time (closeDispute has no window).
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);
        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);

        vm.warp(refundExpiry + 1 days);
        vm.prank(payer);
        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);

        assertFalse(rail0.getPaymentState(PAYMENT_ID).disputed);
    }

    function test_Dispute_ReopenAfterClose() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.startPrank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
        rail0.closeDispute(PAYMENT_ID, p, DISPUTE_REASON);
        assertFalse(rail0.getPaymentState(PAYMENT_ID).disputed);

        // Reopen within the window succeeds.
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
        vm.stopPrank();

        assertTrue(rail0.getPaymentState(PAYMENT_ID).disputed);
    }

    // ============================================================
    //  Dispute: auto-close on full refund
    // ============================================================

    function test_Refund_FullClosesDispute() public {
        // authorize → capture → dispute → full refund auto-closes the dispute.
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6); // refundable = 100e6

        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);
        assertTrue(rail0.getPaymentState(PAYMENT_ID).disputed);

        // Full refund (zeroes refundableAmount) → DisputeClosed(REASON_FULL_REFUND).
        // closedBy is the refund submitter (payee).
        vm.expectEmit(true, true, true, true);
        emit RAIL0.DisputeClosed(PAYMENT_ID, payer, payee, payee, rail0.REASON_FULL_REFUND());
        _refund(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertFalse(s.disputed);
        assertEq(s.refundableAmount, 0);
    }

    function test_Refund_PartialKeepsDispute() public {
        // A partial refund (refundableAmount stays > 0) leaves the dispute open.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);
        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, DISPUTE_REASON);

        vm.recordLogs();
        _refund(PAYMENT_ID, p, 40e6); // refundable 100e6 → 60e6

        // No DisputeClosed emitted.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 closedSig = keccak256("DisputeClosed(bytes32,address,address,address,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != closedSig, "DisputeClosed must not be emitted on partial refund");
        }

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertTrue(s.disputed);
        assertEq(s.refundableAmount, 60e6);
    }

    function test_Refund_FullNoDispute_NoCloseEvent() public {
        // A full refund with no open dispute emits no DisputeClosed.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        vm.recordLogs();
        _refund(PAYMENT_ID, p, 100e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 closedSig = keccak256("DisputeClosed(bytes32,address,address,address,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != closedSig, "DisputeClosed must not be emitted without an open dispute");
        }

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 0);
    }

    // ============================================================
    //  Allowlist
    // ============================================================

    function test_Constructor_RejectsZeroAddress() public {
        address[] memory bad = new address[](1);
        bad[0] = address(0);
        vm.expectRevert(RAIL0.ZeroAddress.selector);
        new RAIL0(bad);
    }

    function test_Constructor_RejectsDuplicate() public {
        address[] memory dup = new address[](2);
        dup[0] = address(token);
        dup[1] = address(token);
        vm.expectRevert(RAIL0.DuplicateToken.selector);
        new RAIL0(dup);
    }

    function test_Constructor_AcceptsMultipleTokens() public {
        MockERC20 t2 = new MockERC20();
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(t2);
        RAIL0 r = new RAIL0(tokens);
        assertTrue(r.isAcceptedToken(address(token)));
        assertTrue(r.isAcceptedToken(address(t2)));
        assertFalse(r.isAcceptedToken(address(0xdead)));
    }

    function test_AcceptedTokens_ReturnsAllowlistInOrder() public {
        MockERC20 t2 = new MockERC20();
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(t2);
        RAIL0 r = new RAIL0(tokens);

        address[] memory got = r.acceptedTokens();
        assertEq(got.length, 2);
        assertEq(got[0], address(token));
        assertEq(got[1], address(t2));
    }

    function test_AcceptedTokens_EmptyWhenNoneAccepted() public {
        address[] memory empty = new address[](0);
        RAIL0 r = new RAIL0(empty);
        assertEq(r.acceptedTokens().length, 0);
    }

    function test_Constructor_EmitsTokenAccepted() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.expectEmit(true, false, false, false);
        emit RAIL0.TokenAccepted(address(token));
        new RAIL0(tokens);
    }

    function test_Constructor_AllowsEmptyList() public {
        address[] memory empty = new address[](0);
        RAIL0 r = new RAIL0(empty);
        assertFalse(r.isAcceptedToken(address(token)));
    }

    function test_TokenNotAccepted_Reverts() public {
        MockERC20 other = new MockERC20();
        RAIL0.Payment memory p = _payment();
        p.token = address(other);
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, other, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.TokenNotAccepted.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    // ============================================================
    //  Validation
    // ============================================================

    function _signForAuthorize(RAIL0.Payment memory p) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        return _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, p.authorizationExpiry, nonce);
    }

    function test_Validation_RejectsBadExpiriesOrder() public {
        // authorizationExpiry > refundExpiry should revert
        RAIL0.Payment memory p = _payment();
        p.authorizationExpiry = uint48(block.timestamp + 30 days);
        p.refundExpiry = uint48(block.timestamp + 7 days);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p);

        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Validation_RejectsZeroAuthorizationExpiry() public {
        RAIL0.Payment memory p = _payment();
        p.authorizationExpiry = 0;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p);

        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Validation_RejectsZeroPayer() public {
        RAIL0.Payment memory p = _payment();
        p.payer = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p);

        vm.expectRevert(RAIL0.ZeroAddress.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Validation_RejectsZeroPayee() public {
        // A zero payee can never submit (no address equals address(0)), so the
        // payee-only gate rejects it before the ZeroAddress validation is reached.
        RAIL0.Payment memory p = _payment();
        p.payee = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p);

        vm.expectRevert(RAIL0.NotPayee.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    function test_Validation_RejectsZeroToken() public {
        RAIL0.Payment memory p = _payment();
        p.token = address(0);
        // Can't sign through `_signForAuthorize` because it touches `token`.
        // Build the digest manually with the original token, but submit with token=0.
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, rail0.hashPayment(p));
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.ZeroAddress.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    /// Equal expiries are now REJECTED. They used to be accepted — the ordering check
    /// uses `>`, not `>=` — which collapsed the refund/dispute window to zero: both
    /// become unreachable the instant the authorization ends, so the payment was
    /// refundable in name only. (#41)
    function test_Validation_RejectsExpiriesEqual() public {
        RAIL0.Payment memory p = _payment();
        uint48 t = uint48(block.timestamp + 10 days);
        p.authorizationExpiry = t;
        p.refundExpiry = t;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    /// The boundary, both sides. Exactly MIN_REFUND_WINDOW is accepted; one second
    /// under is not — so the constant is the real gate, not an approximation of one.
    function test_Validation_RefundWindowBoundary() public {
        uint48 authExpiry = uint48(block.timestamp + 10 days);

        RAIL0.Payment memory ok = _payment();
        ok.authorizationExpiry = authExpiry;
        ok.refundExpiry = authExpiry + rail0.MIN_REFUND_WINDOW();
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(ok);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, ok, v, r, s);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6);

        RAIL0.Payment memory tooTight = _payment();
        tooTight.authorizationExpiry = authExpiry;
        tooTight.refundExpiry = authExpiry + rail0.MIN_REFUND_WINDOW() - 1;
        (v, r, s) = _signForAuthorize(tooTight);
        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(keccak256("too-tight"), tooTight, v, r, s);
    }

    /// charge shares _validatePayment, so it must reject the same shapes — pinned
    /// because a validation added to only one entrypoint is the classic miss.
    function test_Validation_ChargeRejectsACollapsedRefundWindow() public {
        RAIL0.Payment memory p = _payment();
        uint48 t = uint48(block.timestamp + 10 days);
        p.authorizationExpiry = t;
        p.refundExpiry = t;
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, p.authorizationExpiry, nonce);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.charge(PAYMENT_ID, p, v, r, s);
    }

    /// The metric is DAYS: an hours-long window is refused even though it is non-zero.
    function test_Validation_RejectsAnHoursLongRefundWindow() public {
        RAIL0.Payment memory p = _payment();
        p.authorizationExpiry = uint48(block.timestamp + 10 days);
        p.refundExpiry = p.authorizationExpiry + 6 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    // ============================================================
    //  Views
    // ============================================================

    function test_IsAcceptedToken() public {
        assertTrue(rail0.isAcceptedToken(address(token)));
        assertFalse(rail0.isAcceptedToken(address(0xdead)));
        assertFalse(rail0.isAcceptedToken(address(0)));
    }

    function test_HashPayment_Deterministic() public view {
        RAIL0.Payment memory p = _payment();
        bytes32 h1 = rail0.hashPayment(p);
        bytes32 h2 = rail0.hashPayment(p);
        assertEq(h1, h2);
    }

    function test_HashPayment_DiffersWhenAnyFieldChanges() public view {
        RAIL0.Payment memory p1 = _payment();
        bytes32 baseHash = rail0.hashPayment(p1);

        RAIL0.Payment memory p2 = _payment();
        p2.amount = p1.amount + 1;
        assertTrue(rail0.hashPayment(p2) != baseHash);

        RAIL0.Payment memory p3 = _payment();
        p3.refundExpiry = p1.refundExpiry + 1;
        assertTrue(rail0.hashPayment(p3) != baseHash);

        RAIL0.Payment memory p4 = _payment();
        p4.payee = address(0xBEEF);
        assertTrue(rail0.hashPayment(p4) != baseHash);
    }

    function test_AuthorizeNonce_Deterministic() public view {
        bytes32 cfg = bytes32(uint256(0xabc));
        assertEq(rail0.authorizeNonce(PAYMENT_ID, cfg), rail0.authorizeNonce(PAYMENT_ID, cfg));
    }

    function test_AuthorizeNonce_DiffersByPaymentId() public view {
        bytes32 cfg = bytes32(uint256(0xabc));
        bytes32 n1 = rail0.authorizeNonce(keccak256("a"), cfg);
        bytes32 n2 = rail0.authorizeNonce(keccak256("b"), cfg);
        assertTrue(n1 != n2);
    }

    function test_AuthorizeNonce_DiffersByConfigHash() public view {
        bytes32 n1 = rail0.authorizeNonce(PAYMENT_ID, bytes32(uint256(0xaaa)));
        bytes32 n2 = rail0.authorizeNonce(PAYMENT_ID, bytes32(uint256(0xbbb)));
        assertTrue(n1 != n2);
    }

    // ============================================================
    //  EIP-3009 specifics
    // ============================================================

    function test_EIP3009_NonceReusePreventedByPaymentIdUniqueness() public {
        // RAIL0 uses paymentId uniqueness as the primary replay defense.
        // Even if a buyer signs identical args, the second authorize hits
        // PaymentAlreadyExists before reaching the token's nonce check.
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // Attempt to replay
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
    }

    // ============================================================
    //  Front-running the merchant's submission (#35)
    // ============================================================
    //
    // authorize/charge spend the buyer's signature via `receiveWithAuthorization`,
    // whose `msg.sender == to` check is the entire defense: a signature naming RAIL0
    // as `to` is spendable only through RAIL0. These tests pin both direct-to-token
    // routes an attacker could try with a signature lifted from the mempool, then
    // prove the nonce survives for the merchant's real submission.

    function test_FrontRun_AuthorizeSignature_UnusableDirectlyAtToken() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        address attacker = makeAddr("mempool-attacker");

        // Route 1: submit the lifted signature to receiveWithAuthorization directly.
        // The token requires msg.sender == to, and `to` is RAIL0 — not the attacker.
        vm.prank(attacker);
        vm.expectRevert(bytes("EIP3009: caller must be receiver"));
        token.receiveWithAuthorization(payer, address(rail0), p.amount, 0, authorizationExpiry, nonce, v, r, s);

        // Route 2: submit it to transferWithAuthorization, which anyone may call.
        // The signature was produced over the RECEIVE typehash, so the recovered
        // signer differs from the payer and the token rejects it.
        vm.prank(attacker);
        vm.expectRevert(bytes("EIP3009: bad sig"));
        token.transferWithAuthorization(payer, address(rail0), p.amount, 0, authorizationExpiry, nonce, v, r, s);

        // Neither attempt burned the nonce: the merchant's authorize still lands and
        // the funds end up tracked by a live PaymentState.
        vm.prank(payee);
        rail0.authorize(PAYMENT_ID, p, v, r, s);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, p.amount);
        assertEq(token.balanceOf(address(rail0)), p.amount);
    }

    function test_FrontRun_ChargeSignature_UnusableDirectlyAtToken() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payerKey, token, payer, address(rail0), p.amount, 0, authorizationExpiry, nonce);

        address attacker = makeAddr("mempool-attacker");

        vm.prank(attacker);
        vm.expectRevert(bytes("EIP3009: caller must be receiver"));
        token.receiveWithAuthorization(payer, address(rail0), p.amount, 0, authorizationExpiry, nonce, v, r, s);

        vm.prank(payee);
        rail0.charge(PAYMENT_ID, p, v, r, s);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, p.amount);
        assertEq(token.balanceOf(payee), p.amount);
    }

    // ============================================================
    //  EIP-712 / hash commitment
    // ============================================================

    function test_PaymentMismatch_Reverts() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // Tamper with amount; capture should fail hash check
        p.amount = 999e6;
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.capture(PAYMENT_ID, p, 50e6);
    }

    function test_HashPayment_DiffersAcrossDeployments() public {
        RAIL0.Payment memory p = _payment();
        bytes32 h1 = rail0.hashPayment(p);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        RAIL0 other = new RAIL0(tokens);
        bytes32 h2 = other.hashPayment(p);

        assertTrue(h1 != h2, "hashes must differ across deployments (different verifyingContract)");
    }

    function test_DomainSeparator_RebuildsOnChainFork() public {
        bytes32 cached = rail0.DOMAIN_SEPARATOR();
        vm.chainId(999);
        bytes32 fresh = rail0.DOMAIN_SEPARATOR();
        assertTrue(cached != fresh, "domain separator must rebuild on chain fork");
    }

    function test_AuthorizeNonce_DiffersFromChargeNonce() public view {
        bytes32 cfg = bytes32(uint256(0xabc));
        bytes32 a = rail0.authorizeNonce(PAYMENT_ID, cfg);
        bytes32 c = rail0.chargeNonce(PAYMENT_ID, cfg);
        assertTrue(a != c, "authorize and charge nonces must differ");
    }

    // ============================================================
    //  Token compatibility
    // ============================================================

    function test_SafeTransfer_RevertsOnBoolFalseReturn() public {
        // void calls _safeTransfer; verify TransferFailed when token.transfer returns false.
        MockTransferFails badTransfer = new MockTransferFails();
        address[] memory tokens = new address[](1);
        tokens[0] = address(badTransfer);
        RAIL0 r = new RAIL0(tokens);

        // Set up state via authorize (uses receiveWithAuthorization, which works).
        badTransfer.mint(payer, 1000e6);
        RAIL0.Payment memory p = _payment();
        p.token = address(badTransfer);
        bytes32 cfg = r.hashPayment(p);
        bytes32 nonce = r.authorizeNonce(PAYMENT_ID, cfg);
        (uint8 v, bytes32 rr, bytes32 ss) =
            _signReceive3009(payerKey, badTransfer, payer, address(r), p.amount, 0, authorizationExpiry, nonce);
        vm.prank(payee);
        r.authorize(PAYMENT_ID, p, v, rr, ss);

        // Now void → _safeTransfer(token, payer, amount) → token.transfer returns false → revert.
        vm.prank(payee);
        vm.expectRevert(RAIL0.TransferFailed.selector);
        r.void(PAYMENT_ID, p);
    }

    /// ACCEPTED RISK, pinned so a future change surfaces it (#39).
    ///
    /// Every buyer-bound payout is `_safeTransfer(p.token, p.payer, …)` with no alternate
    /// recipient. If the token issuer freezes the PAYER after authorize, `void` and
    /// `release` both revert inside the transfer — and once `authorizationExpiry` passes,
    /// `capture` is closed too, so the escrow has no on-chain path out at all.
    ///
    /// The mirror case (a frozen MERCHANT) is documented in the README as an escape
    /// hatch, because `void`/`release` still reach the buyer. This direction has no
    /// equivalent, and the only mitigation is timing: capture before the deadline.
    function test_FrozenBuyer_EscrowIsStuckAfterExpiry() public {
        MockBlacklistsAddress frozen = new MockBlacklistsAddress();
        address[] memory tokens = new address[](1);
        tokens[0] = address(frozen);
        RAIL0 r = new RAIL0(tokens);

        frozen.mint(payer, 1000e6);
        RAIL0.Payment memory p = _payment();
        p.token = address(frozen);
        bytes32 cfg = r.hashPayment(p);
        bytes32 nonce = r.authorizeNonce(PAYMENT_ID, cfg);
        (uint8 v, bytes32 rr, bytes32 ss) =
            _signReceive3009(payerKey, frozen, payer, address(r), p.amount, 0, authorizationExpiry, nonce);
        vm.prank(payee);
        r.authorize(PAYMENT_ID, p, v, rr, ss);

        // The issuer freezes the buyer. EIP-3009 already pulled the funds, so the escrow
        // is held by RAIL0 and only the OUTBOUND path to the payer is blocked.
        frozen.blacklist(payer);

        // Both buyer-bound exits fail: the transfer to the payer returns false.
        vm.prank(payee);
        vm.expectRevert(RAIL0.TransferFailed.selector);
        r.void(PAYMENT_ID, p);

        // The mitigation, while it lasts: capture still settles to the PAYEE, whose
        // address is not blocked. This is the only way the funds move at all.
        vm.prank(payee);
        r.capture(PAYMENT_ID, p, 1);
        assertEq(frozen.balanceOf(payee), 1, "capture must still reach an unfrozen payee");

        // After the deadline every door is shut.
        vm.warp(authorizationExpiry);

        vm.prank(payee);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        r.capture(PAYMENT_ID, p, 1);

        vm.prank(payer);
        vm.expectRevert(RAIL0.TransferFailed.selector);
        r.release(PAYMENT_ID, p);

        // …and the escrow is still there, unreachable.
        RAIL0.PaymentState memory st = r.getPaymentState(PAYMENT_ID);
        assertGt(st.capturableAmount, 0, "escrow remains, with no path out: the accepted risk");
    }

    // ============================================================
    //  Accounting invariants (fuzz) and the guards that were never pinned (#44)
    // ============================================================

    /// The core accounting invariant, over arbitrary amounts and an arbitrary partial
    /// capture: the two buckets are funded from the payment's immutable amount, so
    /// together they can never exceed it. Every payout path derives from these, and the
    /// whole suite was fixed-value before this — so nothing tested the property itself.
    function testFuzz_CaptureKeepsBucketsWithinAmount(uint120 amount, uint120 captureAmount) public {
        amount = uint120(bound(amount, 1, 10_000e6));
        captureAmount = uint120(bound(captureAmount, 1, amount));

        token.mint(payer, amount);
        RAIL0.Payment memory p = _payment();
        p.amount = amount;
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, captureAmount);

        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertLe(
            uint256(st.capturableAmount) + uint256(st.refundableAmount),
            uint256(amount),
            "capturable + refundable must never exceed the payment amount"
        );
        // Capture moves value between buckets rather than creating it, so with nothing
        // refunded yet the sum is still exactly the amount.
        assertEq(uint256(st.capturableAmount) + uint256(st.refundableAmount), uint256(amount));
    }

    /// The same invariant across a capture AND a refund, which is where an off-by-one in
    /// the bucket arithmetic would show up.
    function testFuzz_CaptureThenRefundKeepsBucketsWithinAmount(
        uint120 amount,
        uint120 captureAmount,
        uint120 refundAmount
    ) public {
        amount = uint120(bound(amount, 2, 10_000e6));
        captureAmount = uint120(bound(captureAmount, 1, amount));
        refundAmount = uint120(bound(refundAmount, 1, captureAmount));

        token.mint(payer, amount);
        token.mint(payee, amount); // the payee funds the refund via EIP-3009
        RAIL0.Payment memory p = _payment();
        p.amount = amount;
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, captureAmount);

        RAIL0.PaymentState memory mid = rail0.getPaymentState(PAYMENT_ID);
        bytes32 nonce = rail0.refundNonce(PAYMENT_ID, rail0.hashPayment(p), mid.capturableAmount, mid.refundableAmount);
        (uint8 v, bytes32 r, bytes32 ss) =
            _signReceive3009(payeeKey, token, payee, address(rail0), refundAmount, 0, refundExpiry, nonce);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, refundAmount, v, r, ss);

        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertLe(
            uint256(st.capturableAmount) + uint256(st.refundableAmount),
            uint256(amount),
            "capturable + refundable must never exceed the payment amount"
        );
    }

    /// The escrow-solvency invariant: the contract must hold at least what it still owes
    /// the buyer. This is the property a non-standard token would break by transferring
    /// less than `value` on the EIP-3009 pull, which the balance-delta discussion in #37
    /// is about — so it is worth asserting on the honest token too, as the baseline.
    function testFuzz_ContractHoldsAtLeastTheCapturableEscrow(uint120 amount, uint120 captureAmount) public {
        amount = uint120(bound(amount, 1, 10_000e6));
        captureAmount = uint120(bound(captureAmount, 1, amount));

        token.mint(payer, amount);
        RAIL0.Payment memory p = _payment();
        p.amount = amount;
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, captureAmount);

        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertGe(
            token.balanceOf(address(rail0)),
            uint256(st.capturableAmount),
            "the contract must hold at least the escrow it still owes the buyer"
        );
    }

    /// `void` deliberately has NO time guard — unlike capture, which closes at
    /// authorizationExpiry. Pinned because the asymmetry is easy to mistake for an
    /// oversight and "tidy up" by adding one, which would strand a buyer's escrow.
    function test_Void_HasNoTimeGuard() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.warp(uint256(authorizationExpiry) + 1 days);

        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), 10_000e6, "void must still return the escrow after expiry");
    }

    /// An open dispute does NOT block capture: `dispute` is signal-only, with no fund
    /// effect (see the README security model). Pinned so the design decision is visible
    /// in the suite rather than only in prose.
    function test_Capture_IsNotBlockedByAnOpenDispute() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p); // charge → everything refundable, so a dispute is meaningful

        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, bytes32(uint256(1)));

        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertTrue(st.disputed, "precondition: the dispute is open");
        assertEq(st.capturableAmount, 0, "charge leaves nothing capturable");
        // Nothing to capture after a charge, so the guard that fires is the amount one —
        // NOT a dispute check, which is the point.
        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 1);
    }

    // ============================================================
    //  Refund-nonce uniqueness (#36)
    // ============================================================

    /// The sequence that used to brick refunds permanently.
    ///
    /// Deriving the nonce from `refundableAmount` alone was safe only while that balance
    /// fell monotonically. `capture` is the one operation that raises it, so it could put
    /// the balance back to a value already used: the nonce repeated, the token refused it
    /// as spent, and because `capturableAmount` was by then exhausted the payee had no way
    /// to move the balance to a fresh value. The residual was permanently non-refundable,
    /// and an open dispute on it could never be resolved.
    function test_Refund_SurvivesARevisitedRefundableBalance() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);
        bytes32 cfg = rail0.getConfigHash(PAYMENT_ID);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 50e6);
        bytes32 firstNonce = rail0.refundNonce(PAYMENT_ID, cfg, 50e6, 50e6);
        _refund(PAYMENT_ID, p, 50e6);
        assertTrue(token.authorizationState(payee, firstNonce), "precondition: first nonce spent");

        // Capture the rest: refundable returns to 50e6 -- the old collision point.
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 50e6);
        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertEq(st.capturableAmount, 0, "escrow exhausted: the balance cannot be moved again");
        assertEq(st.refundableAmount, 50e6, "and it is back to a value already used");

        bytes32 secondNonce = rail0.refundNonce(PAYMENT_ID, cfg, 0, 50e6);
        assertTrue(secondNonce != firstNonce, "the pair differs, so the nonce differs");

        // The refund that was impossible now settles.
        _refund(PAYMENT_ID, p, 50e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 0, "fully refunded");
    }

    /// No nonce may repeat across an ARBITRARY interleaving of captures and refunds.
    ///
    /// The property behind it: `amount - capturable - refundable` never falls -- a capture
    /// moves value between the buckets and leaves it flat, every refund raises it. Since
    /// the pair determines that quantity, two refunds cannot share a pre-refund pair.
    ///
    /// Run against the old single-balance derivation this fails with "REPEATED nonce",
    /// which is what makes it a regression test rather than a restatement.
    function testFuzz_RefundNoncesNeverRepeat(uint120 a, uint120 b, uint120 c, uint120 d) public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);
        bytes32 cfg = rail0.getConfigHash(PAYMENT_ID);

        uint120[4] memory amounts = [
            uint120(bound(a, 1, 25e6)),
            uint120(bound(b, 1, 25e6)),
            uint120(bound(c, 1, 25e6)),
            uint120(bound(d, 1, 25e6))
        ];

        bytes32[4] memory seen;
        uint256 n;
        uint120 prevSettled;

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(payee);
            rail0.capture(PAYMENT_ID, p, amounts[i]);

            RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
            assertEq(p.amount - st.capturableAmount - st.refundableAmount, prevSettled, "a capture leaves it flat");

            bytes32 nonce = rail0.refundNonce(PAYMENT_ID, cfg, st.capturableAmount, st.refundableAmount);
            for (uint256 j = 0; j < n; j++) {
                assertTrue(nonce != seen[j], "REPEATED nonce across refunds");
            }
            seen[n++] = nonce;

            _refund(PAYMENT_ID, p, amounts[i]);

            RAIL0.PaymentState memory settled = rail0.getPaymentState(PAYMENT_ID);
            uint120 nowSettled = p.amount - settled.capturableAmount - settled.refundableAmount;
            assertGt(nowSettled, prevSettled, "a refund strictly raises it");
            prevSettled = nowSettled;
        }
    }

    /// A SUCCESSFUL capture must leave an open dispute open. `capturableAmount` and
    /// `refundableAmount` share a packed slot with `exists` and `disputed`, so any change
    /// to how that slot is written risks carrying the neighbours with it.
    ///
    /// Written while evaluating a whole-struct write for #45 — which was measured and
    /// REJECTED for costing gas — but kept, because the pin is valuable independently
    /// and nothing else covered it. test_Capture_IsNotBlockedByAnOpenDispute does not:
    /// it charges first, so there is nothing capturable and the capture reverts, meaning
    /// a dropped `disputed` would survive it untouched.
    function test_Capture_PreservesAnOpenDispute() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // A dispute needs a refundable balance, so capture part of the escrow first.
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 40e6);

        vm.prank(payer);
        rail0.dispute(PAYMENT_ID, p, bytes32(uint256(1)));
        assertTrue(rail0.getPaymentState(PAYMENT_ID).disputed, "precondition: dispute open");

        // A second, successful capture — escrow remains, so this one goes through.
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 10e6);

        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertTrue(st.disputed, "the whole-slot write must not clear an open dispute");
        assertTrue(st.exists, "nor the exists flag");
        assertEq(st.capturableAmount, 50e6, "escrow reduced by both captures");
        assertEq(st.refundableAmount, 50e6, "and moved to the refundable bucket");
    }

    function test_SafeTransfer_AcceptsNonReturningToken() public {
        // USDT-mainnet style: `transfer` returns NO data. _safeTransfer must accept it
        // (the `data.length == 0` branch — success, no bool to decode), so an outbound
        // transfer with empty return data must NOT revert. Mock the token's transfer to
        // return empty bytes and confirm capture settles.
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector, payee, uint256(100e6)), hex"");
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        assertEq(
            rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0, "capture didn't settle against a non-returning token"
        );
    }

    function test_Refund_RevertsWhenTransferToPayer_Fails() public {
        // receiveWithAuthorization succeeds (tokens move from payee to RAIL0) but
        // the subsequent _safeTransfer(payer) fails. Use vm.mockCall to make
        // token.transfer(payer, ...) return false after the state is set up.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        uint120 refundable = rail0.getPaymentState(PAYMENT_ID).refundableAmount;
        bytes32 nonce =
            rail0.refundNonce(PAYMENT_ID, configHash, rail0.getPaymentState(PAYMENT_ID).capturableAmount, refundable);
        token.mint(payee, 50e6);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);

        // Mock token.transfer(payer, 50e6) to return false.
        vm.mockCall(
            address(token), abi.encodeWithSelector(IERC20.transfer.selector, payer, uint256(50e6)), abi.encode(false)
        );

        vm.expectRevert(RAIL0.TransferFailed.selector);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, s);
    }

    // ============================================================
    //  Reentrancy
    // ============================================================

    /// Transient storage clears at the end of the TRANSACTION, not the call, so the
    /// guard must release the lock explicitly (#45). Without that, the first guarded
    /// call in a transaction would poison every later one.
    ///
    /// Two captures in a single transaction — the shape a multicall or a smart-account
    /// batch produces. Both must go through. This is the regression the move from
    /// storage to transient storage makes possible, and nothing else in the suite would
    /// notice it: every other test makes one guarded call per transaction.
    function test_Reentrancy_TwoGuardedCallsInOneTransaction() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // No vm.prank between them: one broadcast, two guarded entrypoints.
        vm.startPrank(payee);
        rail0.capture(PAYMENT_ID, p, 10e6);
        rail0.capture(PAYMENT_ID, p, 15e6);
        vm.stopPrank();

        RAIL0.PaymentState memory st = rail0.getPaymentState(PAYMENT_ID);
        assertEq(st.capturableAmount, 75e6, "both captures must have applied");
        assertEq(st.refundableAmount, 25e6);
    }

    function test_Reentrancy_GuardBlocksInnerCall() public {
        MockReentrant evil = new MockReentrant();
        address[] memory tokens = new address[](1);
        tokens[0] = address(evil);
        RAIL0 r = new RAIL0(tokens);

        RAIL0.Payment memory p = _payment();
        p.token = address(evil);

        // Outer call: authorize for paymentId. Inner reentry: another authorize for a
        // different paymentId. The reentrancy guard should reject the inner call.
        bytes memory payload = abi.encodeWithSelector(
            r.authorize.selector, keccak256("attack-pid"), p, uint8(27), bytes32(0), bytes32(0)
        );
        evil.arm(address(r), payload);

        // The bogus signature args don't matter — the reentry trips the guard before
        // the token would verify them. Outer authorize uses the same bogus sig because
        // MockReentrant ignores the auth args entirely (it just runs the reentry).
        // The merchant submits the outer call; the inner reentry (from the token) trips
        // the reentrancy guard in the modifier before its own payee check is reached.
        vm.prank(payee);
        r.authorize(PAYMENT_ID, p, uint8(27), bytes32(0), bytes32(0));

        assertTrue(evil.reenterAttempted(), "reentrant token did not actually attempt reentry");
        assertFalse(evil.reenterSucceeded(), "reentrancy guard failed to block inner call");
        // Not just "the inner call failed" — assert it failed for the RIGHT reason:
        // the reentrancy guard, before the token's own payee check. Reentrancy() has
        // no args, so its revert data is exactly the 4-byte selector.
        assertEq(
            evil.reenterRevertData(),
            abi.encodeWithSelector(RAIL0.Reentrancy.selector),
            "inner call did not revert with Reentrancy"
        );
    }

    // ============================================================
    //  End-to-end happy path
    // ============================================================

    function test_E2E_AuthorizeCaptureRefund() public {
        RAIL0.Payment memory p = _payment();
        p.amount = 200e6;

        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 200e6);

        assertEq(token.balanceOf(payee), 200e6);

        // Refund half of the captured amount via EIP-3009 signature
        _refund(PAYMENT_ID, p, 100e6);

        // Payee paid back 100e6 from their own wallet (200e6 received - 100e6 refunded)
        assertEq(token.balanceOf(payee), 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 100e6);
    }

    // ================================================================
    //  Post-event balances carried by the four fund-moving events
    // ================================================================
    //
    // These events carry the escrow balances AS THEY STAND AFTER the operation,
    // so an indexer can read the balance instead of reconstructing it by folding
    // every prior event over its own database — a fold that silently misreports a
    // PARTIAL capture as a FULL one whenever the event stream has a gap.
    //
    // That makes the emitted balances load-bearing for everything downstream, so
    // each one is asserted here against getPaymentState (the on-chain truth they
    // must mirror) rather than against a hand-written literal.

    /// Re-declared locally: vm.expectEmit needs the event in the test's scope.
    event PaymentCaptured(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint120 capturableAmount,
        uint120 refundableAmount
    );
    event PaymentVoided(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint120 capturableAmount,
        uint120 refundableAmount
    );
    event PaymentReleased(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint120 capturableAmount,
        uint120 refundableAmount
    );
    event PaymentRefunded(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint120 capturableAmount,
        uint120 refundableAmount
    );

    function test_Event_Capture_Partial_CarriesPostBalances() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // A partial capture moves 30 out of escrow and into the refundable bucket.
        vm.expectEmit(true, true, true, true);
        emit PaymentCaptured(PAYMENT_ID, payer, payee, 30e6, 70e6, 30e6);
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 70e6, "event must mirror stored capturable");
        assertEq(s.refundableAmount, 30e6, "event must mirror stored refundable");
    }

    function test_Event_Capture_SecondPartial_CarriesRunningBalances() public {
        // The regression this whole change exists for: after a FIRST capture the
        // second event must still state the true remainder, so an indexer that
        // never saw the first one cannot conclude "capturable 0 => fully captured".
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        vm.expectEmit(true, true, true, true);
        emit PaymentCaptured(PAYMENT_ID, payer, payee, 20e6, 50e6, 50e6);
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 20e6);

        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 50e6);
    }

    function test_Event_Capture_Full_CarriesZeroCapturable() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.expectEmit(true, true, true, true);
        emit PaymentCaptured(PAYMENT_ID, payer, payee, 100e6, 0, 100e6);
        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Event_Void_CarriesZeroCapturable() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        // Void drains escrow; nothing was captured, so refundable stays 0.
        vm.expectEmit(true, true, true, true);
        emit PaymentVoided(PAYMENT_ID, payer, payee, 100e6, 0, 0);
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Event_Release_KeepsRefundableFromEarlierCapture() public {
        // Release after a partial capture: escrow goes to 0, but the already
        // captured amount is still refundable and must be reported as such.
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 40e6);

        vm.warp(uint256(p.authorizationExpiry));

        vm.expectEmit(true, true, true, true);
        emit PaymentReleased(PAYMENT_ID, payer, payee, 60e6, 0, 40e6);
        vm.prank(payer);
        rail0.release(PAYMENT_ID, p);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 40e6);
    }

    function test_Event_Refund_Partial_CarriesPostBalances() public {
        // Charge puts the full amount straight into the refundable bucket and
        // leaves escrow empty, so capturable must be reported as 0 throughout.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        bytes32 nonce = rail0.refundNonce(PAYMENT_ID, configHash, 0, 100e6);
        (uint8 v, bytes32 r, bytes32 sig) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 50e6, 0, p.refundExpiry, nonce);

        vm.expectEmit(true, true, true, true);
        emit PaymentRefunded(PAYMENT_ID, payer, payee, 50e6, 0, 50e6);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6, v, r, sig);

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 50e6);
    }

    function test_Event_Refund_Full_CarriesZeroRefundable() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);

        bytes32 configHash = rail0.getConfigHash(PAYMENT_ID);
        bytes32 nonce = rail0.refundNonce(PAYMENT_ID, configHash, 0, 100e6);
        (uint8 v, bytes32 r, bytes32 sig) =
            _signReceive3009(payeeKey, token, payee, address(rail0), 100e6, 0, p.refundExpiry, nonce);

        vm.expectEmit(true, true, true, true);
        emit PaymentRefunded(PAYMENT_ID, payer, payee, 100e6, 0, 0);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 100e6, v, r, sig);

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 0);
    }

    function test_Event_Capture_AfterCharge_IsNotPossible_SoRefundIsTheOnlyPath() public {
        // Guards the assumption behind the refund assertions above: a charged
        // payment holds nothing in escrow, so its events always report capturable 0.
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }
}
