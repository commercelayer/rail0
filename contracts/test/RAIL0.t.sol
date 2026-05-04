// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { RAIL0 } from "../src/RAIL0.sol";

// ================================================================
//  Mock tokens
// ================================================================

/// Standard ERC-20 with EIP-2612 permit.
contract MockERC20 {
    // Lowercase to match the ERC-20 standard's `name()` / `version()` getters.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "Mock Stablecoin";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant version = "1";

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    bytes32 public immutable DOMAIN_SEPARATOR;

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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(deadline >= block.timestamp, "permit: expired");
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == owner, "permit: bad sig");
        allowance[owner][spender] = value;
    }
}

/// USDT-mainnet style: no return value on transfer / transferFrom.
contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Token whose transfer / transferFrom returns false.
contract MockBadReturn {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// Token whose transferFrom calls back into RAIL0 (reentrancy attempt).
contract MockReentrant {
    bool public reenterAttempted;
    bool public reenterSucceeded;
    address public rail0;
    bytes public payload;

    function arm(address _rail0, bytes calldata _payload) external {
        rail0 = _rail0;
        payload = _payload;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        if (rail0 != address(0) && payload.length > 0) {
            reenterAttempted = true;
            (bool ok,) = rail0.call(payload);
            reenterSucceeded = ok;
        }
        return true;
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

    uint48 internal preApprovalExpiry;
    uint48 internal authorizationExpiry;
    uint48 internal refundExpiry;

    bytes32 internal constant PAYMENT_ID = keccak256("test-payment-1");

    function setUp() public {
        token = new MockERC20();

        address[] memory accepted = new address[](1);
        accepted[0] = address(token);
        rail0 = new RAIL0(accepted);

        (payer, payerKey) = makeAddrAndKey("payer");
        (payee, payeeKey) = makeAddrAndKey("payee");

        vm.warp(1_700_000_000);
        preApprovalExpiry = uint48(block.timestamp + 1 hours);
        authorizationExpiry = uint48(block.timestamp + 7 days);
        refundExpiry = uint48(block.timestamp + 30 days);

        token.mint(payer, 10_000e6);

        vm.prank(payer);
        token.approve(address(rail0), type(uint256).max);
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
            preApprovalExpiry: preApprovalExpiry,
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

    function _signPermit(uint256 ownerKey, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, token.nonces(owner), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    // ============================================================
    //  Lifecycle: authorize
    // ============================================================

    function test_Authorize_Success() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertTrue(s.exists);
        assertEq(s.capturableAmount, 100e6);
        assertEq(s.refundableAmount, 0);
        assertEq(token.balanceOf(address(rail0)), 100e6);
        assertEq(token.balanceOf(payer), 10_000e6 - 100e6);
        assertEq(rail0.getConfigHash(PAYMENT_ID), rail0.hashPayment(p));
    }

    function test_Authorize_RevertsIfNotPayer() public {
        RAIL0.Payment memory p = _payment();
        vm.expectRevert(RAIL0.NotPayer.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Authorize_RevertsIfPaymentIdReused() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payer);
        vm.expectRevert(RAIL0.PaymentAlreadyExists.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Authorize_RevertsAtPreApprovalExpiry() public {
        RAIL0.Payment memory p = _payment();
        vm.warp(preApprovalExpiry);
        vm.prank(payer);
        vm.expectRevert(RAIL0.PreApprovalExpired.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Authorize_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        vm.expectRevert(RAIL0.InvalidAmount.selector);
        rail0.authorize(PAYMENT_ID, p, 0);
    }

    function test_Authorize_RevertsIfAmountExceedsMax() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        vm.expectRevert(RAIL0.InvalidAmount.selector);
        rail0.authorize(PAYMENT_ID, p, 1001e6);
    }

    function test_Authorize_EmitsEvent() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit RAIL0.PaymentAuthorized(PAYMENT_ID, payer, payee, p, 100e6);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    // ============================================================
    //  Lifecycle: charge
    // ============================================================

    function test_Charge_Success() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
        assertEq(token.balanceOf(address(rail0)), 0);
    }

    function test_Charge_WithFee_Distributes() public {
        RAIL0.Payment memory p = _paymentWithFee();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);
        // 2.5% fee
        assertEq(token.balanceOf(feeReceiver), 2.5e6);
        assertEq(token.balanceOf(payee), 97.5e6);
    }

    function test_Charge_FullFee_ZeroPayee() public {
        RAIL0.Payment memory p = _paymentWithFee();
        p.feeBps = 10_000;
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);
        assertEq(token.balanceOf(feeReceiver), 100e6);
        assertEq(token.balanceOf(payee), 0);
    }

    // ============================================================
    //  Lifecycle: capture
    // ============================================================

    function test_Capture_Success() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        RAIL0.PaymentState memory s = rail0.getPaymentState(PAYMENT_ID);
        assertEq(s.capturableAmount, 0);
        assertEq(s.refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
    }

    function test_Capture_Partial_Multiple() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

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
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.expectRevert(RAIL0.NotPayee.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsAtAuthExpiry() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        vm.prank(payee);
        vm.expectRevert(RAIL0.AuthorizationExpired.selector);
        rail0.capture(PAYMENT_ID, p, 100e6);
    }

    function test_Capture_RevertsIfAmountTooLarge() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 100e6 + 1);
    }

    function test_Capture_RevertsIfAmountZero() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        vm.expectRevert(RAIL0.InvalidCaptureAmount.selector);
        rail0.capture(PAYMENT_ID, p, 0);
    }

    function test_Capture_WithFee_Distributes() public {
        RAIL0.Payment memory p = _paymentWithFee();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payee);
        rail0.capture(PAYMENT_ID, p, 100e6);

        assertEq(token.balanceOf(feeReceiver), 2.5e6);
        assertEq(token.balanceOf(payee), 97.5e6);
    }

    // ============================================================
    //  Lifecycle: void / reclaim / refund
    // ============================================================

    function test_Void_Success() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.void(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Void_RevertsIfNothingToVoid() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6); // capturable = 0

        vm.prank(payee);
        vm.expectRevert(RAIL0.NothingToVoid.selector);
        rail0.void(PAYMENT_ID, p);
    }

    function test_Reclaim_Success() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.warp(authorizationExpiry);
        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payer);
        rail0.reclaim(PAYMENT_ID, p);

        assertEq(token.balanceOf(payer), balBefore + 100e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 0);
    }

    function test_Reclaim_RevertsBeforeAuthExpiry() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

        vm.prank(payer);
        vm.expectRevert(RAIL0.AuthorizationNotExpired.selector);
        rail0.reclaim(PAYMENT_ID, p);
    }

    function test_Refund_Success() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);

        uint256 balBefore = token.balanceOf(payer);
        vm.prank(payee);
        rail0.refund(PAYMENT_ID, p, 50e6);

        assertEq(token.balanceOf(payer), balBefore + 50e6);
        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 50e6);
    }

    function test_Refund_Partial_Multiple() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);

        vm.startPrank(payee);
        rail0.refund(PAYMENT_ID, p, 30e6);
        rail0.refund(PAYMENT_ID, p, 70e6);
        vm.stopPrank();

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 0);
    }

    function test_Refund_RevertsAtRefundExpiry() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);

        vm.warp(refundExpiry);
        vm.prank(payee);
        vm.expectRevert(RAIL0.RefundExpired.selector);
        rail0.refund(PAYMENT_ID, p, 50e6);
    }

    function test_Refund_RevertsIfNoStandingApproval() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);

        // Revoke payee's approval
        vm.prank(payee);
        token.approve(address(rail0), 0);

        vm.prank(payee);
        vm.expectRevert(); // underflow when token tries to deduct allowance
        rail0.refund(PAYMENT_ID, p, 50e6);
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
        vm.prank(payer);
        vm.expectRevert(RAIL0.TokenNotAccepted.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    // ============================================================
    //  Validation
    // ============================================================

    function test_Validation_RejectsBadExpiriesOrder() public {
        RAIL0.Payment memory p = _payment();
        p.preApprovalExpiry = uint48(block.timestamp + 7 days);
        p.authorizationExpiry = uint48(block.timestamp + 1 hours);
        vm.prank(payer);
        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Validation_RejectsZeroPreApprovalExpiry() public {
        RAIL0.Payment memory p = _payment();
        p.preApprovalExpiry = 0;
        vm.prank(payer);
        vm.expectRevert(RAIL0.InvalidExpiries.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Validation_RejectsHighFeeBps() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 10_001;
        p.feeReceiver = feeReceiver;
        vm.prank(payer);
        vm.expectRevert(RAIL0.FeeBpsTooHigh.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Validation_RejectsZeroFeeReceiverWhenFeeBpsSet() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100;
        p.feeReceiver = address(0);
        vm.prank(payer);
        vm.expectRevert(RAIL0.ZeroFeeReceiver.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Validation_RejectsFeeReceiverEqualsPayer() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100;
        p.feeReceiver = payer;
        vm.prank(payer);
        vm.expectRevert(RAIL0.FeeReceiverIsParty.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    function test_Validation_RejectsFeeReceiverEqualsPayee() public {
        RAIL0.Payment memory p = _payment();
        p.feeBps = 100;
        p.feeReceiver = payee;
        vm.prank(payer);
        vm.expectRevert(RAIL0.FeeReceiverIsParty.selector);
        rail0.authorize(PAYMENT_ID, p, 100e6);
    }

    // ============================================================
    //  EIP-712 / hash commitment
    // ============================================================

    function test_PaymentMismatch_Reverts() public {
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 100e6);

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

    // ============================================================
    //  Permit wrappers
    // ============================================================

    function test_PermitAndAuthorize_Success() public {
        // Reset payer's standing approval to force the permit path
        vm.prank(payer);
        token.approve(address(rail0), 0);

        RAIL0.Payment memory p = _payment();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(payerKey, payer, address(rail0), 100e6, deadline);

        vm.prank(payer);
        rail0.permitAndAuthorize(PAYMENT_ID, p, 100e6, deadline, v, r, s);

        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6);
    }

    function test_PermitAndAuthorize_FallsBackToStandingApproval() public {
        // Standing approval is in place; an invalid permit signature gets swallowed
        RAIL0.Payment memory p = _payment();
        uint256 deadline = block.timestamp + 1 hours;
        // Sign with the wrong key — permit() will revert internally; try/catch swallows it
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(payeeKey, payer, address(rail0), 100e6, deadline);

        vm.prank(payer);
        rail0.permitAndAuthorize(PAYMENT_ID, p, 100e6, deadline, v, r, s);

        assertEq(rail0.getPaymentState(PAYMENT_ID).capturableAmount, 100e6);
    }

    function test_PermitAndCharge_Success() public {
        vm.prank(payer);
        token.approve(address(rail0), 0);

        RAIL0.Payment memory p = _payment();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(payerKey, payer, address(rail0), 100e6, deadline);

        vm.prank(payer);
        rail0.permitAndCharge(PAYMENT_ID, p, 100e6, deadline, v, r, s);

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 100e6);
        assertEq(token.balanceOf(payee), 100e6);
    }

    function test_PermitAndRefund_Success() public {
        // Charge to populate refundable
        RAIL0.Payment memory p = _payment();
        vm.prank(payer);
        rail0.charge(PAYMENT_ID, p, 100e6);

        // Reset payee's approval to force permit path
        vm.prank(payee);
        token.approve(address(rail0), 0);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(payeeKey, payee, address(rail0), 50e6, deadline);

        vm.prank(payee);
        rail0.permitAndRefund(PAYMENT_ID, p, 50e6, deadline, v, r, s);

        assertEq(rail0.getPaymentState(PAYMENT_ID).refundableAmount, 50e6);
    }

    // ============================================================
    //  Token compatibility
    // ============================================================

    function test_USDTStyle_NoReturn() public {
        MockUSDT usdt = new MockUSDT();
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdt);
        RAIL0 r = new RAIL0(tokens);

        usdt.mint(payer, 1000e6);
        vm.prank(payer);
        usdt.approve(address(r), type(uint256).max);

        RAIL0.Payment memory p = _payment();
        p.token = address(usdt);
        vm.prank(payer);
        r.authorize(PAYMENT_ID, p, 100e6);

        assertEq(usdt.balanceOf(address(r)), 100e6);
    }

    function test_BadReturn_Reverts() public {
        MockBadReturn bad = new MockBadReturn();
        address[] memory tokens = new address[](1);
        tokens[0] = address(bad);
        RAIL0 r = new RAIL0(tokens);

        RAIL0.Payment memory p = _payment();
        p.token = address(bad);
        vm.prank(payer);
        vm.expectRevert(RAIL0.TransferFailed.selector);
        r.authorize(PAYMENT_ID, p, 100e6);
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

        // Arm the token to attempt a reentrant call to authorize with a different paymentId
        bytes memory payload = abi.encodeCall(r.authorize, (keccak256("attack-pid"), p, 50e6));
        evil.arm(address(r), payload);

        vm.prank(payer);
        r.authorize(PAYMENT_ID, p, 100e6);

        assertTrue(evil.reenterAttempted(), "reentrant token did not actually attempt reentry");
        assertFalse(evil.reenterSucceeded(), "reentrancy guard failed to block inner call");
    }

    // ============================================================
    //  End-to-end happy path
    // ============================================================

    function test_E2E_AuthorizeCaptureRefund_WithFee() public {
        RAIL0.Payment memory p = _paymentWithFee();

        vm.prank(payer);
        rail0.authorize(PAYMENT_ID, p, 200e6);

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
