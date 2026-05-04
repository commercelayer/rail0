// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { RAIL0 } from "../src/RAIL0.sol";
import { RAIL0Sponsor } from "../src/RAIL0Sponsor.sol";
import { IPaymaster, PackedUserOperation } from "../src/interfaces/IERC4337.sol";

// ================================================================
//  Mock EntryPoint
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

// ================================================================
//  Test contract
// ================================================================

contract RAIL0SponsorTest is Test {
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6;

    RAIL0 internal rail0;
    RAIL0Sponsor internal sponsor;
    MockEntryPoint internal entryPoint;

    address internal sponsorAddr;
    uint256 internal sponsorKey;
    address internal smartAccount = address(0x5A);

    function setUp() public {
        entryPoint = new MockEntryPoint();
        // RAIL0 needs at least one accepted token; the address itself is irrelevant for sponsor tests.
        address[] memory tokens = new address[](1);
        tokens[0] = address(0xDEAD);
        rail0 = new RAIL0(tokens);
        sponsor = new RAIL0Sponsor(address(entryPoint), address(rail0));

        (sponsorAddr, sponsorKey) = makeAddrAndKey("sponsor");
        vm.deal(sponsorAddr, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    // ============================================================
    //  Helpers
    // ============================================================

    function _executeCalldata(address target, bytes memory innerData) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EXECUTE_SELECTOR, target, uint256(0), innerData);
    }

    function _emptyRailCallData(bytes4 sel) internal pure returns (bytes memory) {
        // Inner call with just the selector and no args; sponsor only inspects the selector.
        return abi.encodePacked(sel);
    }

    function _buildUserOp(bytes memory accountCallData) internal view returns (PackedUserOperation memory op) {
        op.sender = smartAccount;
        op.nonce = 0;
        op.callData = accountCallData;
        op.accountGasLimits = bytes32(0);
        op.preVerificationGas = 0;
        op.gasFees = bytes32(0);
        op.signature = "";
    }

    function _signSponsorship(
        uint256 ownerKey,
        bytes32 userOpHash,
        address sponsorParam,
        uint48 validUntil,
        uint48 validAfter
    ) internal view returns (bytes memory sig) {
        bytes32 digest = sponsor.hashSponsorship(userOpHash, sponsorParam, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildPaymasterAndData(address sp, uint48 validUntil, uint48 validAfter, bytes memory sig)
        internal
        view
        returns (bytes memory)
    {
        // [paymaster (20)][verifGas (16)][postOpGas (16)][sponsor (20)][validUntil (6)][validAfter (6)][sig (65)]
        return abi.encodePacked(
            address(sponsor),
            uint128(100_000),
            uint128(50_000),
            sp,
            validUntil,
            validAfter,
            sig
        );
    }

    function _validUserOp(bytes32 userOpHash, uint256 maxCost) internal view returns (PackedUserOperation memory op) {
        bytes memory inner = _emptyRailCallData(RAIL0.authorize.selector);
        op = _buildUserOp(_executeCalldata(address(rail0), inner));
        bytes memory sig = _signSponsorship(sponsorKey, userOpHash, sponsorAddr, type(uint48).max, 0);
        op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, type(uint48).max, 0, sig);
        // suppress unused-var warning
        maxCost;
    }

    // ============================================================
    //  Deposit / withdraw
    // ============================================================

    function test_Deposit_Self_CreditsCallerAndForwardsToEntryPoint() public {
        sponsor.deposit{ value: 1 ether }();
        assertEq(sponsor.deposits(address(this)), 1 ether);
        assertEq(entryPoint.balanceOf(address(sponsor)), 1 ether);
    }

    function test_DepositFor_CreditsNamedSponsor() public {
        sponsor.depositFor{ value: 1 ether }(sponsorAddr);
        assertEq(sponsor.deposits(sponsorAddr), 1 ether);
        assertEq(sponsor.deposits(address(this)), 0);
        assertEq(entryPoint.balanceOf(address(sponsor)), 1 ether);
    }

    function test_DepositFor_RevertsIfZeroAddress() public {
        vm.expectRevert(RAIL0Sponsor.ZeroAddress.selector);
        sponsor.depositFor{ value: 1 ether }(address(0));
    }

    function test_Withdraw_PullsFromOwnBalance() public {
        sponsor.deposit{ value: 2 ether }();
        address payable recipient = payable(address(0xBEEF));
        sponsor.withdraw(recipient, 1 ether);
        assertEq(sponsor.deposits(address(this)), 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_Withdraw_RevertsIfInsufficient() public {
        sponsor.deposit{ value: 1 ether }();
        vm.expectRevert(RAIL0Sponsor.InsufficientDeposit.selector);
        sponsor.withdraw(payable(address(this)), 2 ether);
    }

    function test_Withdraw_RevertsIfZeroAddress() public {
        sponsor.deposit{ value: 1 ether }();
        vm.expectRevert(RAIL0Sponsor.ZeroAddress.selector);
        sponsor.withdraw(payable(address(0)), 1 ether);
    }

    function test_Withdraw_OnlyAffectsCaller() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);
        // address(this) has zero balance even though there are funds in the contract
        vm.expectRevert(RAIL0Sponsor.InsufficientDeposit.selector);
        sponsor.withdraw(payable(address(this)), 1);
    }

    // ============================================================
    //  validatePaymasterUserOp — happy path
    // ============================================================

    function test_Validate_Success_PreDeducts() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        uint256 maxCost = 1 ether;
        PackedUserOperation memory op = _validUserOp(userOpHash, maxCost);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            sponsor.validatePaymasterUserOp(op, userOpHash, maxCost);

        assertEq(sponsor.deposits(sponsorAddr), 4 ether, "maxCost should be pre-deducted");
        assertEq(validationData & 1, 0, "sigFailed bit must be clear");

        (address sp, uint256 mc, bytes32 hashFromCtx) = abi.decode(context, (address, uint256, bytes32));
        assertEq(sp, sponsorAddr);
        assertEq(mc, maxCost);
        assertEq(hashFromCtx, userOpHash);
    }

    function test_Validate_FlagsBadSignature() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _buildUserOp(
            _executeCalldata(address(rail0), _emptyRailCallData(RAIL0.charge.selector))
        );

        // Sign with the wrong key
        (, uint256 wrongKey) = makeAddrAndKey("not-the-sponsor");
        bytes memory sig = _signSponsorship(wrongKey, userOpHash, sponsorAddr, type(uint48).max, 0);
        op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, type(uint48).max, 0, sig);

        vm.prank(address(entryPoint));
        (, uint256 validationData) = sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);

        assertEq(validationData & 1, 1, "sigFailed bit must be set on bad signature");
    }

    function test_Validate_EncodesValidUntilAndAfter() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint48 validAfter = uint48(block.timestamp);

        PackedUserOperation memory op = _buildUserOp(
            _executeCalldata(address(rail0), _emptyRailCallData(RAIL0.authorize.selector))
        );
        bytes memory sig = _signSponsorship(sponsorKey, userOpHash, sponsorAddr, validUntil, validAfter);
        op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, validUntil, validAfter, sig);

        vm.prank(address(entryPoint));
        (, uint256 validationData) = sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);

        uint48 decodedUntil = uint48(validationData >> 160);
        uint48 decodedAfter = uint48(validationData >> 208);
        assertEq(decodedUntil, validUntil);
        assertEq(decodedAfter, validAfter);
    }

    // ============================================================
    //  validatePaymasterUserOp — failure modes
    // ============================================================

    function test_Validate_RevertsIfNotEntryPoint() public {
        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _validUserOp(userOpHash, 1 ether);

        vm.expectRevert(RAIL0Sponsor.OnlyEntryPoint.selector);
        sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
    }

    function test_Validate_RevertsIfPaymasterDataMalformed() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _buildUserOp(
            _executeCalldata(address(rail0), _emptyRailCallData(RAIL0.authorize.selector))
        );
        // Truncated paymaster data (missing sponsor data section)
        op.paymasterAndData = abi.encodePacked(address(sponsor), uint128(0), uint128(0));

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0Sponsor.InvalidPaymasterData.selector);
        sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
    }

    function test_Validate_RevertsIfInsufficientDeposit() public {
        // No deposit
        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _validUserOp(userOpHash, 1 ether);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0Sponsor.InsufficientDeposit.selector);
        sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
    }

    function test_Validate_RevertsIfBadOuterSelector() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        // Wrong outer selector — not execute()
        bytes memory wrongOuter = abi.encodeWithSelector(bytes4(0xdeadbeef), address(rail0), uint256(0), bytes(""));
        PackedUserOperation memory op = _buildUserOp(wrongOuter);
        bytes memory sig = _signSponsorship(sponsorKey, userOpHash, sponsorAddr, type(uint48).max, 0);
        op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, type(uint48).max, 0, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0Sponsor.UnsupportedAccountCall.selector);
        sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
    }

    function test_Validate_RevertsIfTargetNotRAIL0() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _buildUserOp(
            _executeCalldata(address(0xC0FFEE), _emptyRailCallData(RAIL0.authorize.selector))
        );
        bytes memory sig = _signSponsorship(sponsorKey, userOpHash, sponsorAddr, type(uint48).max, 0);
        op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, type(uint48).max, 0, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0Sponsor.TargetNotRAIL0.selector);
        sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
    }

    function test_Validate_RevertsIfBadInnerSelector() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _buildUserOp(
            _executeCalldata(address(rail0), abi.encodePacked(bytes4(0xdeadbeef)))
        );
        bytes memory sig = _signSponsorship(sponsorKey, userOpHash, sponsorAddr, type(uint48).max, 0);
        op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, type(uint48).max, 0, sig);

        vm.prank(address(entryPoint));
        vm.expectRevert(RAIL0Sponsor.UnauthorizedSelector.selector);
        sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
    }

    function test_Validate_AcceptsAllNineRAILSelectors() public {
        sponsor.depositFor{ value: 50 ether }(sponsorAddr);

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

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes32 userOpHash = keccak256(abi.encodePacked("op-", i));
            PackedUserOperation memory op = _buildUserOp(
                _executeCalldata(address(rail0), _emptyRailCallData(selectors[i]))
            );
            bytes memory sig = _signSponsorship(sponsorKey, userOpHash, sponsorAddr, type(uint48).max, 0);
            op.paymasterAndData = _buildPaymasterAndData(sponsorAddr, type(uint48).max, 0, sig);

            vm.prank(address(entryPoint));
            (, uint256 validationData) = sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);
            assertEq(validationData & 1, 0, "all nine selectors must validate");
        }
    }

    // ============================================================
    //  postOp — refund accounting
    // ============================================================

    function test_PostOp_RefundsDifferenceToSponsor() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        uint256 maxCost = 1 ether;
        PackedUserOperation memory op = _validUserOp(userOpHash, maxCost);

        vm.prank(address(entryPoint));
        (bytes memory context,) = sponsor.validatePaymasterUserOp(op, userOpHash, maxCost);

        assertEq(sponsor.deposits(sponsorAddr), 4 ether);

        // Actual gas cost was much less than maxCost
        uint256 actualCost = 0.3 ether;
        vm.prank(address(entryPoint));
        sponsor.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 0);

        // Sponsor's balance: 5 - 1 (pre-deduct) + 0.7 (refund) = 4.7 ether
        assertEq(sponsor.deposits(sponsorAddr), 4.7 ether);
    }

    function test_PostOp_NoRefundWhenActualEqualsMax() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        uint256 maxCost = 1 ether;
        PackedUserOperation memory op = _validUserOp(userOpHash, maxCost);

        vm.prank(address(entryPoint));
        (bytes memory context,) = sponsor.validatePaymasterUserOp(op, userOpHash, maxCost);

        vm.prank(address(entryPoint));
        sponsor.postOp(IPaymaster.PostOpMode.opSucceeded, context, maxCost, 0);

        assertEq(sponsor.deposits(sponsorAddr), 4 ether);
    }

    function test_PostOp_RevertsIfNotEntryPoint() public {
        bytes memory ctx = abi.encode(sponsorAddr, uint256(1 ether), bytes32(0));
        vm.expectRevert(RAIL0Sponsor.OnlyEntryPoint.selector);
        sponsor.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.5 ether, 0);
    }

    function test_PostOp_EmitsSponsoredEvent() public {
        sponsor.depositFor{ value: 5 ether }(sponsorAddr);

        bytes32 userOpHash = keccak256("op-1");
        PackedUserOperation memory op = _validUserOp(userOpHash, 1 ether);

        vm.prank(address(entryPoint));
        (bytes memory context,) = sponsor.validatePaymasterUserOp(op, userOpHash, 1 ether);

        vm.prank(address(entryPoint));
        vm.expectEmit(true, true, false, true);
        emit RAIL0Sponsor.Sponsored(sponsorAddr, userOpHash, 0.3 ether);
        sponsor.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.3 ether, 0);
    }

    // ============================================================
    //  EIP-712
    // ============================================================

    function test_HashSponsorship_DiffersAcrossDeployments() public {
        bytes32 userOpHash = keccak256("op-1");
        bytes32 h1 = sponsor.hashSponsorship(userOpHash, sponsorAddr, type(uint48).max, 0);

        RAIL0Sponsor other = new RAIL0Sponsor(address(entryPoint), address(rail0));
        bytes32 h2 = other.hashSponsorship(userOpHash, sponsorAddr, type(uint48).max, 0);

        assertTrue(h1 != h2, "digests must differ across deployments");
    }

    function test_DomainSeparator_RebuildsOnChainFork() public {
        bytes32 cached = sponsor.DOMAIN_SEPARATOR();
        vm.chainId(999);
        bytes32 fresh = sponsor.DOMAIN_SEPARATOR();
        assertTrue(cached != fresh);
    }

    // ============================================================
    //  Constructor
    // ============================================================

    function test_Constructor_RevertsIfZeroEntryPoint() public {
        vm.expectRevert(RAIL0Sponsor.ZeroAddress.selector);
        new RAIL0Sponsor(address(0), address(rail0));
    }

    function test_Constructor_RevertsIfZeroRAIL0() public {
        vm.expectRevert(RAIL0Sponsor.ZeroAddress.selector);
        new RAIL0Sponsor(address(entryPoint), address(0));
    }
}
