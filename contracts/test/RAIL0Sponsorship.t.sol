// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { RAIL0 } from "../src/RAIL0.sol";
import { IPaymaster, PackedUserOperation } from "../src/interfaces/IERC4337.sol";

// ================================================================
//  Mocks (kept self-contained for test isolation)
// ================================================================

contract MockEntryPoint {
    mapping(address => uint256) public balanceOf;

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function depositTo(address account) external payable {
        balanceOf[account] += msg.value;
    }

    function withdrawTo(address payable to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "MockEntryPoint: withdraw failed");
    }
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
}

// ================================================================
//  Test contract
// ================================================================

contract RAIL0SponsorshipTest is Test {
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6;

    RAIL0 internal rail0;
    MockEntryPoint internal entryPoint;
    MockToken internal token;

    address internal payee;        // merchant — also the sponsor identity
    uint256 internal payeeKey;     // merchant signing key
    address internal payer = address(0x1A);
    address internal smartAccount; // buyer's smart account

    uint48 internal preApprovalExpiry;
    uint48 internal authorizationExpiry;
    uint48 internal refundExpiry;

    bytes32 internal constant PAYMENT_ID = keccak256("sponsor-test-1");

    function setUp() public {
        entryPoint = new MockEntryPoint();
        token = new MockToken();

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        rail0 = new RAIL0(tokens, address(entryPoint));

        (payee, payeeKey) = makeAddrAndKey("merchant");
        smartAccount = makeAddr("buyer-sca");

        vm.deal(payee, 100 ether);
        vm.deal(address(this), 100 ether);

        vm.warp(1_700_000_000);
        preApprovalExpiry = uint48(block.timestamp + 1 hours);
        authorizationExpiry = uint48(block.timestamp + 7 days);
        refundExpiry = uint48(block.timestamp + 30 days);
    }

    // ============================================================
    //  Helpers
    // ============================================================

    function _payment() internal view returns (RAIL0.Payment memory p) {
        p.payer = payer;
        p.payee = payee;
        p.token = address(token);
        p.maxAmount = 1000e6;
        p.preApprovalExpiry = preApprovalExpiry;
        p.authorizationExpiry = authorizationExpiry;
        p.refundExpiry = refundExpiry;
        p.feeBps = 0;
        p.feeReceiver = address(0);
    }

    function _innerAuthorizeCall(bytes32 paymentId, RAIL0.Payment memory p, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(RAIL0.authorize.selector, paymentId, p, amount);
    }

    function _executeCall(address target, bytes memory innerData) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EXECUTE_SELECTOR, target, uint256(0), innerData);
    }

    function _buildUserOp(bytes memory accountCallData) internal view returns (PackedUserOperation memory op) {
        op.sender = smartAccount;
        op.callData = accountCallData;
        op.signature = "";
    }

    function _signSponsorship(uint256 ownerKey, bytes32 paymentId, bytes32 configHash, uint48 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = rail0.hashSponsorship(paymentId, configHash, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildPaymasterAndData(uint48 deadline, bytes memory sig) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(rail0),
            uint128(100_000),
            uint128(50_000),
            deadline,
            sig
        );
    }

    function _validOp(uint48 deadline) internal view returns (PackedUserOperation memory op) {
        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        bytes memory inner = _innerAuthorizeCall(PAYMENT_ID, p, 100e6);
        op = _buildUserOp(_executeCall(address(rail0), inner));
        bytes memory sig = _signSponsorship(payeeKey, PAYMENT_ID, configHash, deadline);
        op.paymasterAndData = _buildPaymasterAndData(deadline, sig);
    }

    /// Build a syntactically valid inner call for any of the nine sponsorable selectors.
    /// Decoder only reads paymentId (offset 4..36) and Payment (offset 36..324); trailing
    /// args are filler that just satisfies the minimum-length check.
    function _innerForSelector(bytes4 sel, RAIL0.Payment memory p) internal pure returns (bytes memory) {
        if (sel == RAIL0.void.selector || sel == RAIL0.reclaim.selector) {
            return abi.encodeWithSelector(sel, PAYMENT_ID, p);
        }
        if (
            sel == RAIL0.permitAndAuthorize.selector || sel == RAIL0.permitAndCharge.selector
                || sel == RAIL0.permitAndRefund.selector
        ) {
            return abi.encodeWithSelector(
                sel, PAYMENT_ID, p, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0)
            );
        }
        return abi.encodeWithSelector(sel, PAYMENT_ID, p, uint256(100e6));
    }

    // ============================================================
    //  Deposit / withdraw
    // ============================================================

    function test_DepositGas_CreditsCallerAndForwardsToEntryPoint() public {
        rail0.depositGas{ value: 1 ether }();
        assertEq(rail0.gasDeposits(address(this)), 1 ether);
        assertEq(entryPoint.balanceOf(address(rail0)), 1 ether);
    }

    function test_DepositGasFor_CreditsNamedMerchant() public {
        rail0.depositGasFor{ value: 1 ether }(payee);
        assertEq(rail0.gasDeposits(payee), 1 ether);
        assertEq(rail0.gasDeposits(address(this)), 0);
        assertEq(entryPoint.balanceOf(address(rail0)), 1 ether);
    }

    function test_DepositGasFor_RevertsIfZeroAddress() public {
        vm.expectRevert(RAIL0.ZeroAddress.selector);
        rail0.depositGasFor{ value: 1 ether }(address(0));
    }

    function test_WithdrawGas_PullsFromOwnBalance() public {
        rail0.depositGas{ value: 2 ether }();
        address payable recipient = payable(address(0xBEEF));
        rail0.withdrawGas(recipient, 1 ether);
        assertEq(rail0.gasDeposits(address(this)), 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_WithdrawGas_RevertsIfInsufficient() public {
        rail0.depositGas{ value: 1 ether }();
        vm.expectRevert(RAIL0.InsufficientGasDeposit.selector);
        rail0.withdrawGas(payable(address(this)), 2 ether);
    }

    function test_WithdrawGas_RevertsIfZeroAddress() public {
        rail0.depositGas{ value: 1 ether }();
        vm.expectRevert(RAIL0.ZeroAddress.selector);
        rail0.withdrawGas(payable(address(0)), 1 ether);
    }

    function test_WithdrawGas_OnlyAffectsCaller() public {
        rail0.depositGasFor{ value: 5 ether }(payee);
        vm.expectRevert(RAIL0.InsufficientGasDeposit.selector);
        rail0.withdrawGas(payable(address(this)), 1);
    }

    // ============================================================
    //  validatePaymasterUserOp — happy path
    // ============================================================

    function test_Validate_Success_PreDeducts() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        uint48 deadline = type(uint48).max;
        PackedUserOperation memory op = _validOp(deadline);

        uint256 maxCost = 1 ether;
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            rail0.validatePaymasterUserOp(op, bytes32(0), maxCost);

        assertEq(rail0.gasDeposits(payee), 4 ether, "maxCost should be pre-deducted");
        assertEq(validationData & 1, 0, "sigFailed bit must be clear");

        (address sp, uint256 mc, bytes32 paymentIdFromCtx) =
            abi.decode(context, (address, uint256, bytes32));
        assertEq(sp, payee);
        assertEq(mc, maxCost);
        assertEq(paymentIdFromCtx, PAYMENT_ID);
    }

    function test_Validate_EncodesDeadlineAsValidUntil() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        uint48 deadline = uint48(block.timestamp + 1 days);
        PackedUserOperation memory op = _validOp(deadline);

        vm.prank(address(entryPoint));
        (, uint256 validationData) = rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);

        // Safe casts: those bit ranges were packed from uint48s upstream.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 decodedUntil = uint48(validationData >> 160);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 decodedAfter = uint48(validationData >> 208);
        assertEq(decodedUntil, deadline);
        assertEq(decodedAfter, 0); // we always pack validAfter = 0
    }

    function test_Validate_AcceptsAllNineRAILSelectors() public {
        rail0.depositGasFor{ value: 50 ether }(payee);

        bytes4[9] memory selectors = [
            RAIL0.authorize.selector,
            RAIL0.charge.selector,
            RAIL0.capture.selector,
            RAIL0.void.selector,
            RAIL0.reclaim.selector,
            RAIL0.refund.selector,
            RAIL0.permitAndAuthorize.selector,
            RAIL0.permitAndCharge.selector,
            RAIL0.permitAndRefund.selector
        ];

        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        uint48 deadline = type(uint48).max;

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes memory inner = _innerForSelector(selectors[i], p);
            PackedUserOperation memory op = _buildUserOp(_executeCall(address(rail0), inner));
            bytes memory sig = _signSponsorship(payeeKey, PAYMENT_ID, configHash, deadline);
            op.paymasterAndData = _buildPaymasterAndData(deadline, sig);

            vm.prank(address(entryPoint));
            (, uint256 validationData) = rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
            assertEq(validationData & 1, 0, "all nine selectors must validate");
        }
    }

    // ============================================================
    //  validatePaymasterUserOp — failure modes
    // ============================================================

    function test_Validate_RevertsIfNotEntryPoint() public {
        rail0.depositGasFor{ value: 5 ether }(payee);
        PackedUserOperation memory op = _validOp(type(uint48).max);

        vm.expectRevert(RAIL0.OnlyEntryPoint.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsIfPaymasterDataMalformed() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        RAIL0.Payment memory p = _payment();
        bytes memory inner = _innerAuthorizeCall(PAYMENT_ID, p, 100e6);
        PackedUserOperation memory op = _buildUserOp(_executeCall(address(rail0), inner));
        op.paymasterAndData = abi.encodePacked(address(rail0), uint128(0), uint128(0));

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.InvalidPaymasterData.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsOnBadSignature() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        uint48 deadline = type(uint48).max;
        bytes memory inner = _innerAuthorizeCall(PAYMENT_ID, p, 100e6);
        PackedUserOperation memory op = _buildUserOp(_executeCall(address(rail0), inner));

        // Sign with the wrong key
        (, uint256 wrongKey) = makeAddrAndKey("not-the-merchant");
        bytes memory sig = _signSponsorship(wrongKey, PAYMENT_ID, configHash, deadline);
        op.paymasterAndData = _buildPaymasterAndData(deadline, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.InvalidSponsorship.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsOnConfigHashMismatch() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        // Sponsor signs over a DIFFERENT (tampered) configHash. We allocate two
        // independent Payment structs to avoid memory aliasing — `tampered = p`
        // would be a reference assignment, not a copy.
        RAIL0.Payment memory tampered = _payment();
        tampered.maxAmount = 9999e6;
        bytes32 tamperedHash = rail0.hashPayment(tampered);
        uint48 deadline = type(uint48).max;
        bytes memory sig = _signSponsorship(payeeKey, PAYMENT_ID, tamperedHash, deadline);

        // The actual UserOp uses the original Payment terms.
        RAIL0.Payment memory p = _payment();
        bytes memory inner = _innerAuthorizeCall(PAYMENT_ID, p, 100e6);
        PackedUserOperation memory op = _buildUserOp(_executeCall(address(rail0), inner));
        op.paymasterAndData = _buildPaymasterAndData(deadline, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.InvalidSponsorship.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsIfInsufficientGasDeposit() public {
        // No deposit
        PackedUserOperation memory op = _validOp(type(uint48).max);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.InsufficientGasDeposit.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsIfBadOuterSelector() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        uint48 deadline = type(uint48).max;
        bytes memory inner = _innerAuthorizeCall(PAYMENT_ID, p, 100e6);

        bytes memory wrongOuter = abi.encodeWithSelector(bytes4(0xdeadbeef), address(rail0), uint256(0), inner);
        PackedUserOperation memory op = _buildUserOp(wrongOuter);
        bytes memory sig = _signSponsorship(payeeKey, PAYMENT_ID, configHash, deadline);
        op.paymasterAndData = _buildPaymasterAndData(deadline, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.UnsupportedAccountCall.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsIfTargetNotSelf() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        uint48 deadline = type(uint48).max;
        bytes memory inner = _innerAuthorizeCall(PAYMENT_ID, p, 100e6);

        PackedUserOperation memory op = _buildUserOp(_executeCall(address(0xC0FFEE), inner));
        bytes memory sig = _signSponsorship(payeeKey, PAYMENT_ID, configHash, deadline);
        op.paymasterAndData = _buildPaymasterAndData(deadline, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.TargetNotSelf.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_Validate_RevertsIfBadInnerSelector() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        RAIL0.Payment memory p = _payment();
        bytes32 configHash = rail0.hashPayment(p);
        uint48 deadline = type(uint48).max;

        bytes memory inner = abi.encodeWithSelector(bytes4(0xdeadbeef), PAYMENT_ID, p);
        PackedUserOperation memory op = _buildUserOp(_executeCall(address(rail0), inner));
        bytes memory sig = _signSponsorship(payeeKey, PAYMENT_ID, configHash, deadline);
        op.paymasterAndData = _buildPaymasterAndData(deadline, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0.UnauthorizedSelector.selector);
        rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    // ============================================================
    //  postOp — refund accounting
    // ============================================================

    function test_PostOp_RefundsDifferenceToMerchant() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        uint256 maxCost = 1 ether;
        PackedUserOperation memory op = _validOp(type(uint48).max);

        vm.prank(address(entryPoint));
        (bytes memory context,) = rail0.validatePaymasterUserOp(op, bytes32(0), maxCost);

        assertEq(rail0.gasDeposits(payee), 4 ether);

        uint256 actualCost = 0.3 ether;
        vm.prank(address(entryPoint));
        rail0.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 0);

        // 5 - 1 (pre-deduct) + 0.7 (refund) = 4.7 ether
        assertEq(rail0.gasDeposits(payee), 4.7 ether);
    }

    function test_PostOp_NoRefundWhenActualEqualsMax() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        uint256 maxCost = 1 ether;
        PackedUserOperation memory op = _validOp(type(uint48).max);

        vm.prank(address(entryPoint));
        (bytes memory context,) = rail0.validatePaymasterUserOp(op, bytes32(0), maxCost);

        vm.prank(address(entryPoint));
        rail0.postOp(IPaymaster.PostOpMode.opSucceeded, context, maxCost, 0);

        assertEq(rail0.gasDeposits(payee), 4 ether);
    }

    function test_PostOp_RevertsIfNotEntryPoint() public {
        bytes memory ctx = abi.encode(payee, uint256(1 ether), bytes32(0));
        vm.expectRevert(RAIL0.OnlyEntryPoint.selector);
        rail0.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.5 ether, 0);
    }

    function test_PostOp_EmitsSponsoredEvent() public {
        rail0.depositGasFor{ value: 5 ether }(payee);

        PackedUserOperation memory op = _validOp(type(uint48).max);

        vm.prank(address(entryPoint));
        (bytes memory context,) = rail0.validatePaymasterUserOp(op, bytes32(0), 1 ether);

        vm.prank(address(entryPoint));
        vm.expectEmit(true, true, false, true);
        emit RAIL0.Sponsored(payee, PAYMENT_ID, 0.3 ether);
        rail0.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.3 ether, 0);
    }

    // ============================================================
    //  EIP-712 hash digests
    // ============================================================

    function test_HashSponsorship_DiffersAcrossDeployments() public {
        bytes32 configHash = bytes32(uint256(0xabc));
        bytes32 h1 = rail0.hashSponsorship(PAYMENT_ID, configHash, type(uint48).max);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        RAIL0 other = new RAIL0(tokens, address(entryPoint));
        bytes32 h2 = other.hashSponsorship(PAYMENT_ID, configHash, type(uint48).max);

        assertTrue(h1 != h2, "digests must differ across deployments");
    }

    // ============================================================
    //  Constructor
    // ============================================================

    function test_Constructor_RevertsIfZeroEntryPoint() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.expectRevert(RAIL0.ZeroAddress.selector);
        new RAIL0(tokens, address(0));
    }
}
