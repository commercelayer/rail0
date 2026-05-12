// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { RAIL0 } from "../src/RAIL0.sol";

// ================================================================
//  Mock tokens
// ================================================================

/// Standard ERC-20 with EIP-3009 `transferWithAuthorization`.
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
}

/// Token with working EIP-3009 but whose `transfer` returns false. Used to verify
/// that `_safeTransfer` reverts with `TransferFailed` on bool=false return.
contract MockTransferFails is MockERC20 {
    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// Token with working EIP-3009 but whose `transferFrom` returns false. Used to
/// verify that `_safeTransferFrom` reverts with `TransferFailed` on bool=false.
contract MockTransferFromFails is MockERC20 {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// Token that maintains a per-address blacklist (USDC-style freeze). Transfer to a
/// blacklisted address reverts. Used to verify the fee-receiver DoS escape hatch:
/// capture/charge revert if feeReceiver is blacklisted, but void/release still
/// work because they don't call _distribute.
contract MockBlacklistERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    function blacklist(address a) external {
        blacklisted[a] = true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(!blacklisted[to], "blacklisted");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Token whose transferWithAuthorization calls back into RAIL0 (reentrancy attempt).
contract MockReentrant {
    bool public reenterAttempted;
    bool public reenterSucceeded;
    address public rail0;
    bytes public payload;

    function arm(address _rail0, bytes calldata _payload) external {
        rail0 = _rail0;
        payload = _payload;
    }

    function transferWithAuthorization(address, address, uint256, uint256, uint256, bytes32, uint8, bytes32, bytes32)
        external
    {
        if (rail0 != address(0) && payload.length > 0) {
            reenterAttempted = true;
            (bool ok,) = rail0.call(payload);
            reenterSucceeded = ok;
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
    address internal feeReceiver = address(0xC0FFEE);

    uint48 internal authorizationExpiry;
    uint48 internal refundExpiry;

    bytes32 internal constant PAYMENT_ID = keccak256("test-payment-1");
    uint256 internal constant FAR_FUTURE = type(uint256).max;

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

        // Merchant pre-approves RAIL0 for refund pulls.
        vm.prank(payee);
        token.approve(address(rail0), type(uint256).max);
    }

    // ============================================================
    //  Helpers
    // ============================================================

    function _payment() internal view returns (RAIL0.Payment memory) {
        return RAIL0.Payment({
            payer: payer,
            payee: payee,
            token: address(token),
            maxAmount: 1000e6,
            authorizationExpiry: authorizationExpiry,
            refundExpiry: refundExpiry,
            feeBps: 0,
            feeReceiver: address(0)
        });
    }

    function _paymentWithFee() internal view returns (RAIL0.Payment memory p) {
        p = _payment();
        p.feeBps = 250; // 2.5%
        p.feeReceiver = feeReceiver;
    }

    /// Sign an EIP-3009 TransferWithAuthorization for the given token, with the
    /// nonce derived as RAIL0 would expect for either an authorize or charge call.
    function _sign3009(
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
            abi.encode(t.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", t.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    /// Submit `authorize` as the merchant on behalf of the payer.
    function _authorize(bytes32 paymentId, RAIL0.Payment memory p, uint256 amount) internal {
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(paymentId, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), amount, 0, authorizationExpiry, nonce);
        vm.prank(payee);
        rail0.authorize(paymentId, p, amount, v, r, s);
    }

    function _charge(bytes32 paymentId, RAIL0.Payment memory p, uint256 amount) internal {
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(paymentId, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), amount, 0, authorizationExpiry, nonce);
        vm.prank(payee);
        rail0.charge(paymentId, p, amount, v, r, s);
    }

    // ============================================================
    //  Lifecycle: authorize
    // ============================================================

    function test_Authorize_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertTrue(s.exists);
        assertEq(s.capturableAmount, 100e6);
        assertEq(s.refundableAmount, 0);
        assertEq(token.balanceOf(address(rail0)), 100e6);
        assertEq(token.balanceOf(payer), 10_000e6 - 100e6);
        assertEq(rail0.getConfigHash(PAYMENT_ID), rail0.hashPayment(p));
    }

    function test_Authorize_AnyoneCanSubmit() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.prank(makeAddr("random-relayer"));
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);

        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6);
    }

    function test_Authorize_RevertsOnWrongSigner() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        // Sign with payee key instead of payer
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payeeKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        // Token reverts inside transferWithAuthorization on bad sig — bubbles through RAIL0.
        vm.expectRevert();
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Authorize_RevertsOnTamperedAmount() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        // Buyer signed for 100e6
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        // Merchant tries to submit with 200e6 — token's signed value won't match
        vm.expectRevert();
        rail0.authorize(PAYMENT_ID, p, 200e6, v, r, s);
    }

    function test_Authorize_RevertsOnTamperedPayment() public {
        // Two distinct allocations to avoid memory aliasing.
        RAIL0.Payment memory signed = _payment();
        bytes32 signedHash = rail0.hashPayment(signed);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, signedHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        // Submit with tampered Payment — the contract will derive a different nonce
        RAIL0.Payment memory tampered = _payment();
        tampered.maxAmount = 9999e6;

        vm.expectRevert();
        rail0.authorize(PAYMENT_ID, tampered, 100e6, v, r, s);
    }

    function test_Authorize_RevertsAfterAuthorizationExpiry() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Authorize_ChargeNonceDoesNotWorkForAuthorize() public {
        // Buyer signs with the CHARGE nonce — merchant tries to use it for authorize
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 chargeNonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, chargeNonce);

        vm.expectRevert();
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Authorize_RevertsIfPaymentIdReused() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Authorize_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 0, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.InvalidAmount.selector);
        rail0.authorize(PAYMENT_ID, p, 0, v, r, s);
    }

    function test_Authorize_RevertsIfAmountExceedsMax() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 1001e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.InvalidAmount.selector);
        rail0.authorize(PAYMENT_ID, p, 1001e6, v, r, s);
    }

    function test_Authorize_EmitsEvent() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectEmit(true, true, true, true);
        emit RAIL0.PaymentAuthorized(PAYMENT_ID, payer, payee, p, 100e6);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    // ============================================================
    //  Lifecycle: charge
    // ============================================================

    function test_Charge_Success() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
        assertEq(token.balanceOf(address(rail0)), 0);
    }

    function test_Charge_WithFee_Distributes() public {
        RAIL0.Payment memory p = _paymentWithFee();
        _charge(PAYMENT_ID, p, 100e6);
        assertEq(token.balanceOf(feeReceiver), 2.5e6);
        assertEq(token.balanceOf(payee), 97.5e6);
    }

    function test_Charge_FullFee_ZeroPayee() public {
        RAIL0.Payment memory p = _paymentWithFee();
        p.feeBps = 10_000;
        _charge(PAYMENT_ID, p, 100e6);
        assertEq(token.balanceOf(feeReceiver), 100e6);
        assertEq(token.balanceOf(payee), 0);
    }

    function test_Charge_AuthorizeNonceDoesNotWorkForCharge() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 authNonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, authNonce);

        vm.expectRevert();
        rail0.charge(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Charge_AnyoneCanSubmit() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.prank(makeAddr("random-relayer"));
        rail0.charge(PAYMENT_ID, p, 100e6, v, r, s);

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 100e6);
    }

    function test_Charge_RevertsOnWrongSigner() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payeeKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert();
        rail0.charge(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Charge_RevertsOnTamperedAmount() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert();
        rail0.charge(PAYMENT_ID, p, 200e6, v, r, s);
    }

    function test_Charge_RevertsOnTamperedPayment() public {
        RAIL0.Payment memory signed = _payment();
        bytes32 signedHash = rail0.hashPayment(signed);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, signedHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        RAIL0.Payment memory tampered = _payment();
        tampered.maxAmount = 9999e6;

        vm.expectRevert();
        rail0.charge(PAYMENT_ID, tampered, 100e6, v, r, s);
    }

    function test_Charge_RevertsAfterAuthorizationExpiry() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        rail0.charge(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Charge_RevertsIfPaymentIdReused() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        rail0.charge(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Charge_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 0, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.InvalidAmount.selector);
        rail0.charge(PAYMENT_ID, p, 0, v, r, s);
    }

    function test_Charge_RevertsIfAmountExceedsMax() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 1001e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.InvalidAmount.selector);
        rail0.charge(PAYMENT_ID, p, 1001e6, v, r, s);
    }

    function test_Charge_EmitsEvent() public {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.chargeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectEmit(true, true, true, true);
        emit RAIL0.PaymentCharged(PAYMENT_ID, payer, payee, p, 100e6);
        rail0.charge(PAYMENT_ID, p, 100e6, v, r, s);
    }

    // ============================================================
    //  Lifecycle: capture
    // ============================================================

    function test_Capture_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
    }

    function test_Capture_Partial_Multiple() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

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
        _authorize(PAYMENT_ID, p, 100e6);

        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsAtAuthExpiry() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        vm.prank(payee);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsIfAmountTooLarge() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 100e6 + 1);
    }

    function test_Capture_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 0);
    }

    function test_Capture_WithFee_Distributes() public {
        RAIL0.Payment memory p = _paymentWithFee();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        assertEq(token.balanceOf(feeReceiver), 2.5e6);
        assertEq(token.balanceOf(payee), 97.5e6);
    }

    // ============================================================
    //  Fee distribution: rounding & dust
    // ============================================================
    //
    // _distribute uses floor division: fee = (amount * feeBps) / 10_000.
    // Invariants verified by these tests:
    //   1. Sub-unit dust rounds toward the payee (fee receiver eats the loss).
    //   2. Conservation: feeReceiver + payee == amount, exactly, for every input.
    //   3. No overflow at uint120.max amount × max feeBps.
    //   4. Splitting one capture into N partials lowers total fees because each
    //      partial floors to fee=0 independently — documented behavior, not a bug.

    /// @dev feeBps=250 (2.5%), amount=39 → fee=(39*250)/10000=0. Payee gets full 39.
    function test_Capture_FeeRoundsDownDustToZero() public {
        RAIL0.Payment memory p = _paymentWithFee(); // feeBps=250
        _authorize(PAYMENT_ID, p, 39);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 39);

        assertEq(token.balanceOf(feeReceiver), 0, "fee floors to 0");
        assertEq(token.balanceOf(payee), 39, "payee absorbs the dust");
    }

    /// @dev feeBps=250, amount=399 → (399*250)/10000 = 99750/10000 = 9 (truncated from 9.975).
    ///      Payee gets 390, fee receiver gets 9. Conservation: 9 + 390 == 399.
    function test_Capture_FeeRoundsDownTowardsPayee() public {
        RAIL0.Payment memory p = _paymentWithFee();
        _authorize(PAYMENT_ID, p, 399);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 399);

        assertEq(token.balanceOf(feeReceiver), 9, "9.975 floored to 9");
        assertEq(token.balanceOf(payee), 390);
    }

    /// @dev Conservation check across a table of (feeBps, amount) — payee + feeReceiver
    ///      must equal amount exactly for every combination.
    function test_Capture_FeeMath_Conservation() public {
        uint16[5] memory bpsTable = [uint16(1), 100, 250, 9_999, 10_000];
        uint120[5] memory amountTable = [uint120(1), 7, 9_999, 100e6, 1e18];

        for (uint256 i = 0; i < bpsTable.length; i++) {
            for (uint256 j = 0; j < amountTable.length; j++) {
                _runConservationCase(bpsTable[i], amountTable[j], i * amountTable.length + j);
            }
        }
    }

    /// @dev Helper extracted to keep stack pressure down inside the nested loop above.
    function _runConservationCase(uint16 bps, uint120 amount, uint256 salt) internal {
        bytes32 paymentId = keccak256(abi.encodePacked("conservation", salt));

        RAIL0.Payment memory p = _payment();
        p.maxAmount = amount;
        p.feeBps = bps;
        p.feeReceiver = bps == 0 ? address(0) : feeReceiver;

        // Top up payer so we don't run out across iterations.
        token.mint(payer, amount);

        uint256 payeeBefore = token.balanceOf(payee);
        uint256 feeRcvBefore = token.balanceOf(feeReceiver);

        _charge(paymentId, p, amount);

        uint256 paidToPayee = token.balanceOf(payee) - payeeBefore;
        uint256 paidToFee = token.balanceOf(feeReceiver) - feeRcvBefore;

        assertEq(paidToPayee + paidToFee, amount, "conservation: payee + fee == amount");
        assertEq(paidToFee, (uint256(amount) * bps) / 10_000, "fee matches floor formula");
    }

    /// @dev Stress the multiplication: amount near uint120.max × max feeBps must not overflow
    ///      and must distribute correctly. uint120.max ≈ 1.3e36; × 9999 ≈ 1.3e40, far below 2^256.
    function test_Capture_FeeMath_NoOverflowAtMaxAmount() public {
        uint120 huge = type(uint120).max;

        RAIL0.Payment memory p = _payment();
        p.maxAmount = huge;
        p.feeBps = 9_999;
        p.feeReceiver = feeReceiver;

        token.mint(payer, huge);

        _charge(PAYMENT_ID, p, huge);

        uint256 expectedFee = (uint256(huge) * 9_999) / 10_000;
        assertEq(token.balanceOf(feeReceiver), expectedFee);
        assertEq(token.balanceOf(payee), uint256(huge) - expectedFee);
        assertEq(token.balanceOf(feeReceiver) + token.balanceOf(payee), huge, "conservation at max");
    }

    /// @dev Splitting captures lowers total fee due to per-partial flooring. With feeBps=100
    ///      (1%) on 99 units: one capture → fee=0 (floors); 33+33+33 → also 0 each. With
    ///      feeBps=100 on 9999: one capture → fee=99; 3333+3333+3333 → 33+33+33=99 (no loss).
    ///      But on 100 with feeBps=100: one capture → fee=1; 50+50 → 0+0 = 0 (lost fee).
    ///      This test pins down that documented gotcha.
    function test_Capture_SplittingPartialsCanReduceTotalFee() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100; // 1%
        p.feeReceiver = feeReceiver;

        _authorize(PAYMENT_ID, p, 100);

        vm.startPrank(payee);
        rail0.capture(PAYMENT_ID, p, 50);
        rail0.capture(PAYMENT_ID, p, 50);
        vm.stopPrank();

        assertEq(token.balanceOf(feeReceiver), 0, "two 50-unit captures: each fee floors to 0");
        assertEq(token.balanceOf(payee), 100, "merchant kept the dust both times");
    }

    /// @dev Same dust scenario via charge (one-shot): on a 39-unit charge at feeBps=250,
    ///      fee is 0 and payee receives the full 39. Verifies _distribute behaves
    ///      identically when invoked from the charge path.
    function test_Charge_FeeRoundsDownDustToZero() public {
        RAIL0.Payment memory p = _paymentWithFee();
        _charge(PAYMENT_ID, p, 39);

        assertEq(token.balanceOf(feeReceiver), 0);
        assertEq(token.balanceOf(payee), 39);
    }

    // ============================================================
    //  Lifecycle: void / release / refund
    // ============================================================

    function test_Void_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Void_RevertsIfNothingToVoid() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6); // capturable = 0

        vm.prank(payee);
        vm.expectRevert(RAIL0.NothingToVoid.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Release_Success() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        uint256 balBefore = token.balanceOf(payer);
        vm.prank(makeAddr("watchdog"));
        rail0.release(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Release_RevertsBeforeAuthExpiry() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.expectRevert(RAIL0.AuthorizationNotExpired.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Refund_Success() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6);

        assertEq(token.balanceOf(payer), balBefore + 50e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 50e6);
    }

    function test_Refund_Partial_Multiple() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.startPrank(payee);
        rail0.refund(PAYMENT_ID, p, 30e6);
        rail0.refund(PAYMENT_ID, p, 70e6);
        vm.stopPrank();

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 0);
    }

    function test_Refund_RevertsAtRefundExpiry() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.warp(refundExpiry);
        vm.prank(payee);
        vm.expectRevert(RAIL0.RefundExpired.selector);
        rail0.refund(PAYMENT_ID, p, 50e6);
    }

    function test_Refund_RevertsIfNoStandingApproval() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        token.approve(address(rail0), 0);

        vm.prank(payee);
        vm.expectRevert(); // underflow when token tries to deduct allowance
        rail0.refund(PAYMENT_ID, p, 50e6);
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
        _authorize(PAYMENT_ID, p, 100e6);

        // Tamper with any field — capture should reject
        p.maxAmount = 9999e6;
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.capture(PAYMENT_ID, p, 50e6);
    }

    function test_Capture_LeavesRemainingCapturable() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 70e6);
        assertEq(s.refundableAmount, 30e6);
    }

    function test_Void_RevertsIfNotPayee() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

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
        _authorize(PAYMENT_ID, p, 100e6);

        p.maxAmount = 9999e6;
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Void_AfterPartialCapture_VoidsRemaining() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 30e6);

        // Void should release the remaining 70e6 to buyer; refundable stays at 30e6.
        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 70e6);
        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 30e6);
    }

    function test_Release_AnyoneCanCall() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        // Submit from a totally unrelated address
        vm.prank(makeAddr("anyone"));
        rail0.release(PAYMENT_ID, p);

        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Release_RevertsIfNothingToRelease() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        // Void first → capturable = 0
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.NothingToRelease.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        p.maxAmount = 9999e6;
        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_AfterCharge_RevertsNothingToRelease() public {
        // charge sets capturable = 0; release after authorizationExpiry should revert
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.NothingToRelease.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_AfterFullCapture_RevertsNothingToRelease() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        vm.expectRevert(RAIL0.NothingToRelease.selector);
        rail0.release(PAYMENT_ID, p);
    }

    function test_Release_AtExactAuthExpiry_Succeeds() public {
        // Boundary: block.timestamp == authorizationExpiry should succeed
        // (the check is `block.timestamp < authorizationExpiry` revert).
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        rail0.release(PAYMENT_ID, p);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Refund_RevertsIfNotPayee() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.refund(PAYMENT_ID, p, 50e6);
    }

    function test_Refund_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidRefundAmount.selector);
        rail0.refund(PAYMENT_ID, p, 0);
    }

    function test_Refund_RevertsIfAmountExceedsRefundable() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidRefundAmount.selector);
        rail0.refund(PAYMENT_ID, p, 101e6);
    }

    function test_Refund_RevertsIfNonExistent() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentNotFound.selector);
        rail0.refund(PAYMENT_ID, p, 50e6);
    }

    function test_Refund_RevertsIfPaymentMismatch() public {
        RAIL0.Payment memory p = _payment();
        _charge(PAYMENT_ID, p, 100e6);

        p.maxAmount = 9999e6;
        vm.prank(payee);
        vm.expectRevert(RAIL0.PaymentMismatch.selector);
        rail0.refund(PAYMENT_ID, p, 50e6);
    }

    function test_Refund_AfterCapture_Workflow() public {
        // authorize → capture → refund: refund pulls from merchant wallet
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 100e6);

        uint256 payerBalBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 40e6);

        assertEq(token.balanceOf(payee), 60e6);
        assertEq(token.balanceOf(payer), payerBalBefore + 40e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 60e6);
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
            _sign3009(payerKey, other, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.TokenNotAccepted.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    // ============================================================
    //  Validation
    // ============================================================

    function _signForAuthorize(RAIL0.Payment memory p, uint256 amount)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        return _sign3009(payerKey, token, payer, address(rail0), amount, 0, p.authorizationExpiry, nonce);
    }

    function test_Validation_RejectsBadExpiriesOrder() public {
        // authorizationExpiry > refundExpiry should revert
        RAIL0.Payment memory p = _payment();
        p.authorizationExpiry = uint48(block.timestamp + 30 days);
        p.refundExpiry = uint48(block.timestamp + 7 days);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsZeroAuthorizationExpiry() public {
        RAIL0.Payment memory p = _payment();
        p.authorizationExpiry = 0;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsHighFeeBps() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 10_001;
        p.feeReceiver = feeReceiver;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.FeeBpsTooHigh.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsZeroFeeReceiverWhenFeeBpsSet() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100;
        p.feeReceiver = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.ZeroFeeReceiver.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsFeeReceiverEqualsPayer() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100;
        p.feeReceiver = payer;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.FeeReceiverIsParty.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsFeeReceiverEqualsPayee() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100;
        p.feeReceiver = payee;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.FeeReceiverIsParty.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsZeroPayer() public {
        RAIL0.Payment memory p = _payment();
        p.payer = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.ZeroAddress.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsZeroPayee() public {
        RAIL0.Payment memory p = _payment();
        p.payee = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        vm.expectRevert(RAIL0.ZeroAddress.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_RejectsZeroToken() public {
        RAIL0.Payment memory p = _payment();
        p.token = address(0);
        // Can't sign through `_signForAuthorize` because it touches `token`.
        // Build the digest manually with the original token, but submit with token=0.
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, rail0.hashPayment(p));
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.ZeroAddress.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    function test_Validation_AcceptsExpiriesEqual() public {
        // authorizationExpiry == refundExpiry should be allowed
        // (the contract uses `>` not `>=` in the ordering check).
        RAIL0.Payment memory p = _payment();
        uint48 t = uint48(block.timestamp + 1 hours);
        p.authorizationExpiry = t;
        p.refundExpiry = t;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6);
    }

    function test_Validation_AcceptsMaxFeeBpsWithReceiver() public {
        // feeBps == 10000 (100%) is the boundary — should be accepted.
        RAIL0.Payment memory p = _payment();
        p.feeBps = 10_000;
        p.feeReceiver = feeReceiver;
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, 100e6);

        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6);
    }

    function test_Validation_AcceptsAmountEqualMax() public {
        // Boundary: amount == maxAmount should succeed (uses `<=`).
        RAIL0.Payment memory p = _payment();
        (uint8 v, bytes32 r, bytes32 s) = _signForAuthorize(p, p.maxAmount);

        rail0.authorize(PAYMENT_ID, p, p.maxAmount, v, r, s);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, p.maxAmount);
    }

    // ============================================================
    //  Distribute (fee splitting)
    // ============================================================

    function test_Distribute_RoundsFeeDown() public {
        // Tiny amount × small bps rounds the fee down to 0.
        // amount=1, feeBps=100 (1%) → fee = 1*100/10000 = 0 → all goes to payee.
        RAIL0.Payment memory p = _paymentWithFee(); // feeBps = 250
        p.feeBps = 100;
        _charge(PAYMENT_ID, p, 1);

        assertEq(token.balanceOf(feeReceiver), 0);
        assertEq(token.balanceOf(payee), 1);
    }

    function test_Distribute_NoFeeWhenAmountTooSmall() public {
        // Verify that when fee rounds to 0, no `transfer` is even attempted to feeReceiver.
        // (Implementation should `if (fee > 0)` skip the call entirely.)
        RAIL0.Payment memory p = _paymentWithFee();
        p.feeReceiver = feeReceiver; // address that hasn't received tokens yet
        p.feeBps = 1; // 0.01%
        _charge(PAYMENT_ID, p, 99); // 99*1/10000 = 0 (rounds down)

        assertEq(token.balanceOf(feeReceiver), 0);
        assertEq(token.balanceOf(payee), 99);
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
        p2.maxAmount = p1.maxAmount + 1;
        assertTrue(rail0.hashPayment(p2) != baseHash);

        RAIL0.Payment memory p3 = _payment();
        p3.feeBps = 1;
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
        _authorize(PAYMENT_ID, p, 100e6);

        // Attempt to replay
        bytes32 configHash = rail0.hashPayment(p);
        bytes32 nonce = rail0.authorizeNonce(PAYMENT_ID, configHash);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign3009(payerKey, token, payer, address(rail0), 100e6, 0, authorizationExpiry, nonce);

        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6, v, r, s);
    }

    // ============================================================
    //  EIP-712 / hash commitment
    // ============================================================

    function test_PaymentMismatch_Reverts() public {
        RAIL0.Payment memory p = _payment();
        _authorize(PAYMENT_ID, p, 100e6);

        // Tamper with maxAmount; capture should fail hash check
        p.maxAmount = 999e6;
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

        // Set up state via authorize (uses transferWithAuthorization, which works).
        badTransfer.mint(payer, 1000e6);
        RAIL0.Payment memory p = _payment();
        p.token = address(badTransfer);
        bytes32 cfg = r.hashPayment(p);
        bytes32 nonce = r.authorizeNonce(PAYMENT_ID, cfg);
        (uint8 v, bytes32 rr, bytes32 ss) =
            _sign3009(payerKey, badTransfer, payer, address(r), 100e6, 0, authorizationExpiry, nonce);
        r.authorize(PAYMENT_ID, p, 100e6, v, rr, ss);

        // Now void → _safeTransfer(token, payer, amount) → token.transfer returns false → revert.
        vm.prank(payee);
        vm.expectRevert(RAIL0.TransferFailed.selector);
        r.void(PAYMENT_ID, p);
    }

    function test_SafeTransferFrom_RevertsOnBoolFalseReturn() public {
        // refund calls _safeTransferFrom; verify TransferFailed when token.transferFrom
        // returns false. We use charge to set up refundable state — charge only uses
        // transferWithAuthorization + transfer (both work on this mock); refund is the
        // only path that calls transferFrom.
        MockTransferFromFails badTF = new MockTransferFromFails();
        address[] memory tokens = new address[](1);
        tokens[0] = address(badTF);
        RAIL0 r = new RAIL0(tokens);
        badTF.mint(payer, 1000e6);

        RAIL0.Payment memory p = _payment();
        p.token = address(badTF);
        bytes32 cfg = r.hashPayment(p);
        bytes32 nonce = r.chargeNonce(PAYMENT_ID, cfg);
        (uint8 v, bytes32 rr, bytes32 ss) =
            _sign3009(payerKey, badTF, payer, address(r), 100e6, 0, authorizationExpiry, nonce);
        r.charge(PAYMENT_ID, p, 100e6, v, rr, ss);

        vm.prank(payee);
        badTF.approve(address(r), type(uint256).max);

        vm.prank(payee);
        vm.expectRevert(RAIL0.TransferFailed.selector);
        r.refund(PAYMENT_ID, p, 50e6);
    }

    // ============================================================
    //  Fee-receiver DoS resilience (token-level blacklist)
    // ============================================================
    //
    // capture/charge call _distribute → token.transfer(feeReceiver, fee). If the
    // token issuer freezes feeReceiver (USDC-style), those calls revert. void
    // and release skip _distribute entirely and route funds directly to the payer,
    // so the buyer's funds always have an escape hatch.

    /// @dev Helper: deploy a fresh blacklist token + RAIL0, fund payer, authorize
    ///      with a fee, and return everything wired up so each test can blacklist
    ///      the fee receiver and exercise its specific path.
    function _setupBlacklistAuthorize() internal returns (MockBlacklistERC20 bToken, RAIL0 r, RAIL0.Payment memory p) {
        bToken = new MockBlacklistERC20();
        address[] memory tokens = new address[](1);
        tokens[0] = address(bToken);
        r = new RAIL0(tokens);
        bToken.mint(payer, 1000e6);

        p = _payment();
        p.token = address(bToken);
        p.feeBps = 250;
        p.feeReceiver = feeReceiver;

        bytes32 cfg = r.hashPayment(p);
        bytes32 nonce = r.authorizeNonce(PAYMENT_ID, cfg);
        (uint8 v, bytes32 rr, bytes32 ss) =
            _sign3009(payerKey, bToken, payer, address(r), 100e6, 0, authorizationExpiry, nonce);
        r.authorize(PAYMENT_ID, p, 100e6, v, rr, ss);
    }

    function test_Capture_RevertsIfFeeReceiverBlacklisted() public {
        (MockBlacklistERC20 bToken, RAIL0 r, RAIL0.Payment memory p) = _setupBlacklistAuthorize();
        bToken.blacklist(feeReceiver);

        vm.prank(payee);
        vm.expectRevert(); // token reverts inside _distribute → capture aborts
        r.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Void_WorksEvenIfFeeReceiverBlacklisted() public {
        (MockBlacklistERC20 bToken, RAIL0 r, RAIL0.Payment memory p) = _setupBlacklistAuthorize();
        bToken.blacklist(feeReceiver);

        uint256 payerBefore = bToken.balanceOf(payer);
        vm.prank(payee);
        r.void(PAYMENT_ID, p);
        assertEq(bToken.balanceOf(payer), payerBefore + 100e6, "void returns full escrow to payer");
    }

    function test_Release_WorksEvenIfFeeReceiverBlacklisted() public {
        (MockBlacklistERC20 bToken, RAIL0 r, RAIL0.Payment memory p) = _setupBlacklistAuthorize();
        bToken.blacklist(feeReceiver);

        vm.warp(uint256(p.authorizationExpiry));
        uint256 payerBefore = bToken.balanceOf(payer);
        r.release(PAYMENT_ID, p); // anyone may call
        assertEq(bToken.balanceOf(payer), payerBefore + 100e6, "release returns full escrow to payer");
    }

    // ============================================================
    //  Reentrancy
    // ============================================================

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
            r.authorize.selector,
            keccak256("attack-pid"),
            p,
            uint256(50e6),
            uint256(0),
            FAR_FUTURE,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
        evil.arm(address(r), payload);

        // The bogus signature args don't matter — the reentry trips the guard before
        // the token would verify them. Outer authorize uses the same bogus sig because
        // MockReentrant ignores the auth args entirely (it just runs the reentry).
        r.authorize(PAYMENT_ID, p, 100e6, uint8(27), bytes32(0), bytes32(0));

        assertTrue(evil.reenterAttempted(), "reentrant token did not actually attempt reentry");
        assertFalse(evil.reenterSucceeded(), "reentrancy guard failed to block inner call");
    }

    // ============================================================
    //  End-to-end happy path
    // ============================================================

    function test_E2E_AuthorizeCaptureRefund_WithFee() public {
        RAIL0.Payment memory p = _paymentWithFee();

        _authorize(PAYMENT_ID, p, 200e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 200e6);

        assertEq(token.balanceOf(feeReceiver), 5e6);
        assertEq(token.balanceOf(payee), 195e6);

        // Refund half of the gross captured amount
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 100e6);

        // Payee paid back 100e6 from their own wallet
        assertEq(token.balanceOf(payee), 95e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 100e6);
    }
}
