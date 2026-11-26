// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { SettleSafeEscrow } from "../src/SettleSafeEscrow.sol";
import { SettleSafeReactive } from "../src/SettleSafeReactive.sol";

/// @notice Stand-in for the Reactive system contract, etched onto its
///         real address so the reactive contract's typed calls find code
///         there in local tests. Records the last callback requested.
contract MockSystemContract is ISystemContract {
    uint256 public callbackCount;
    uint256 public lastChainId;
    address public lastRecipient;
    bytes public lastPayload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallback(CallbackVersion, bytes memory) external { }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        callbackCount++;
        lastChainId = config_.chainId;
        lastRecipient = config_.recipient;
        lastPayload = config_.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function pay(uint256) external { }

    receive() external payable { }
}

contract SettleSafeTest is Test {
    address payable internal constant SYSTEM = payable(0x8888888888888888888888888888888888888888);
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant CREATED_TOPIC_0 =
        uint256(keccak256("EscrowCreated(uint256,address,address,address,uint256,uint64)"));
    uint256 internal constant CONFIRMED_TOPIC_0 = uint256(keccak256("DeliveryConfirmed(uint256)"));

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address courier = makeAddr("courier");
    address payable proxy = payable(makeAddr("callbackProxy"));
    address reactiveAddr = makeAddr("reactive");

    SettleSafeEscrow escrow;

    MockSystemContract mockSystem;

    function setUp() public {
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM, address(impl).code);
        mockSystem = MockSystemContract(SYSTEM);
        escrow = new SettleSafeEscrow{ value: 0.05 ether }(IPayable(proxy), reactiveAddr);
        vm.deal(buyer, 10 ether);
    }

    function _create(uint64 deadline) internal returns (uint256 id) {
        vm.prank(buyer);
        id = escrow.createEscrow{ value: 0.01 ether }(seller, courier, deadline);
    }

    // ---------- Escrow ----------

    function testCreateEscrowStoresTerms() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        uint256 id = _create(deadline);
        (address b, address s, address c, uint256 amount, uint64 dl, SettleSafeEscrow.State st, bool confirmed) =
            escrow.escrows(id);
        assertEq(b, buyer);
        assertEq(s, seller);
        assertEq(c, courier);
        assertEq(amount, 0.01 ether);
        assertEq(dl, deadline);
        assertEq(uint256(st), uint256(SettleSafeEscrow.State.Open));
        assertFalse(confirmed);
    }

    function testConfirmDeliveryOnlyCourier() public {
        uint256 id = _create(uint64(block.timestamp + 1 hours));
        vm.prank(buyer);
        vm.expectRevert("not courier");
        escrow.confirmDelivery(id);
        vm.prank(courier);
        escrow.confirmDelivery(id);
        (,,,,,, bool confirmed) = escrow.escrows(id);
        assertTrue(confirmed);
    }

    function testReleaseViaCallbackPaysSeller() public {
        uint256 id = _create(uint64(block.timestamp + 1 hours));
        vm.prank(courier);
        escrow.confirmDelivery(id);
        uint256 before = seller.balance;
        vm.prank(proxy);
        escrow.release(reactiveAddr, id);
        assertEq(seller.balance, before + 0.01 ether);
        (,,,,, SettleSafeEscrow.State st,) = escrow.escrows(id);
        assertEq(uint256(st), uint256(SettleSafeEscrow.State.Released));
    }

    function testReleaseRejectsDirectCall() public {
        uint256 id = _create(uint64(block.timestamp + 1 hours));
        vm.prank(courier);
        escrow.confirmDelivery(id);
        vm.prank(buyer);
        vm.expectRevert();
        escrow.release(reactiveAddr, id);
    }

    function testReleaseRejectsWrongReactiveSender() public {
        uint256 id = _create(uint64(block.timestamp + 1 hours));
        vm.prank(courier);
        escrow.confirmDelivery(id);
        vm.prank(proxy);
        vm.expectRevert();
        escrow.release(buyer, id); // injected sender is not our reactive contract
    }

    function testRefundViaCallbackAfterDeadline() public {
        uint64 deadline = uint64(block.timestamp + 10 minutes);
        uint256 id = _create(deadline);
        uint256 before = buyer.balance;
        vm.warp(deadline + 1);
        vm.prank(proxy);
        escrow.refund(reactiveAddr, id);
        assertEq(buyer.balance, before + 0.01 ether);
    }

    function testRefundBeforeDeadlineReverts() public {
        uint256 id = _create(uint64(block.timestamp + 1 hours));
        vm.prank(proxy);
        vm.expectRevert("deadline not reached");
        escrow.refund(reactiveAddr, id);
    }

    // ---------- Reactive ----------

    function _createdLog(uint256 id, uint64 deadline) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(escrow),
            topic0: CREATED_TOPIC_0,
            topic1: id,
            topic2: 0,
            topic3: 0,
            data: abi.encode(buyer, seller, courier, 0.01 ether, deadline),
            blockNumber: 0,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _simpleLog(uint256 topic0, uint256 topic1) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(escrow),
            topic0: topic0,
            topic1: topic1,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 0,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _deployReactive() internal returns (SettleSafeReactive r) {
        r = new SettleSafeReactive{ value: 1 ether }();
        r.watchEscrow(address(escrow));
    }

    function _assertCallbackRequested(string memory sig, uint256 id) internal view {
        assertEq(mockSystem.callbackCount(), 1);
        assertEq(mockSystem.lastChainId(), 84532);
        assertEq(mockSystem.lastRecipient(), address(escrow));
        assertEq(mockSystem.lastPayload(), abi.encodeWithSignature(sig, address(0), id));
    }

    function testReactiveTracksEscrow() public {
        SettleSafeReactive r = _deployReactive();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.prank(SYSTEM);
        r.react(_createdLog(7, deadline));
        (uint64 dl, bool settled, bool exists) = r.tracks(7);
        assertEq(dl, deadline);
        assertFalse(settled);
        assertTrue(exists);
        assertEq(r.trackedIds(0), 7);
    }

    function testReactiveRequestsReleaseOnDelivery() public {
        SettleSafeReactive r = _deployReactive();
        vm.prank(SYSTEM);
        r.react(_createdLog(3, uint64(block.timestamp + 1 hours)));
        vm.prank(SYSTEM);
        r.react(_simpleLog(CONFIRMED_TOPIC_0, 3));
        _assertCallbackRequested("release(address,uint256)", 3);
        (, bool settled,) = r.tracks(3);
        assertTrue(settled);
    }

    function testReactiveRequestsRefundOnCronAfterDeadline() public {
        SettleSafeReactive r = _deployReactive();
        uint64 deadline = uint64(block.timestamp + 10 minutes);
        vm.prank(SYSTEM);
        r.react(_createdLog(5, deadline));
        vm.warp(deadline + 1);
        vm.prank(SYSTEM);
        r.react(_simpleLog(CRON100_TOPIC_0, 0));
        _assertCallbackRequested("refund(address,uint256)", 5);
        (, bool settled,) = r.tracks(5);
        assertTrue(settled);
    }

    function testReactiveCronBeforeDeadlineLeavesEscrowOpen() public {
        SettleSafeReactive r = _deployReactive();
        vm.prank(SYSTEM);
        r.react(_createdLog(9, uint64(block.timestamp + 1 hours)));
        vm.prank(SYSTEM);
        r.react(_simpleLog(CRON100_TOPIC_0, 0));
        (, bool settled,) = r.tracks(9);
        assertFalse(settled);
        assertEq(mockSystem.callbackCount(), 0);
    }

    function testReactRejectsNonSystemCaller() public {
        SettleSafeReactive r = _deployReactive();
        vm.prank(buyer);
        vm.expectRevert();
        r.react(_simpleLog(CONFIRMED_TOPIC_0, 1));
    }
}
