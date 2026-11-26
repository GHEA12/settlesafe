// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/**
 * @title SettleSafeEscrow — destination contract on Base Sepolia.
 * @notice A "set it and forget it" escrow for small peer-to-peer deals.
 *         The buyer funds an escrow and names a seller, a courier, and a
 *         deadline. Settlement is never pushed by the buyer or seller:
 *         - the courier's delivery confirmation is only an event; the
 *           Reactive contract on Lasna hears it and calls back `release`.
 *         - if the deadline passes with no confirmation, the Reactive
 *           contract's cron watcher calls back `refund`.
 *         `release`/`refund` therefore accept calls from the Reactive
 *         callback proxy only, and only when the injected sender is our
 *         reactive contract (see AbstractCallback).
 * @dev The constructor's payable value is the float this contract uses to
 *      pay the callback proxy for deliveries (callbacks are billed to the
 *      recipient in the destination chain's native token). Escrowed funds
 *      share the same balance at this demo scale; keep the float well
 *      above the sum of open escrows.
 */
contract SettleSafeEscrow is AbstractCallback {
    enum State {
        Open,
        Released,
        Refunded
    }

    struct Escrow {
        address buyer;
        address seller;
        address courier;
        uint256 amount;
        uint64 deadline;
        State state;
        bool deliveryConfirmed;
    }

    mapping(uint256 => Escrow) public escrows;
    uint256 public nextId = 1;

    event EscrowCreated(
        uint256 indexed id, address buyer, address seller, address courier, uint256 amount, uint64 deadline
    );
    event DeliveryConfirmed(uint256 indexed id);
    event Released(uint256 indexed id, address seller, uint256 amount);
    event Refunded(uint256 indexed id, address buyer, uint256 amount);

    constructor(IPayable callbackProxy_, address reactive_) payable AbstractCallback(callbackProxy_, reactive_) { }

    /// @notice Buyer funds a new escrow. Deadline is a unix timestamp
    ///         (Base Sepolia mines 200ms blocks — never count blocks).
    function createEscrow(address seller_, address courier_, uint64 deadline_)
        external
        payable
        returns (uint256 id)
    {
        require(msg.value > 0, "no value");
        require(seller_ != address(0) && courier_ != address(0), "bad party");
        require(deadline_ > block.timestamp, "deadline in past");
        id = nextId++;
        escrows[id] = Escrow(msg.sender, seller_, courier_, msg.value, deadline_, State.Open, false);
        emit EscrowCreated(id, msg.sender, seller_, courier_, msg.value, deadline_);
    }

    /// @notice The courier signals delivery. This only emits the event the
    ///         reactive contract is subscribed to; the money moves when
    ///         the network calls back `release`.
    function confirmDelivery(uint256 id_) external {
        Escrow storage e = escrows[id_];
        require(e.state == State.Open, "not open");
        require(msg.sender == e.courier, "not courier");
        require(!e.deliveryConfirmed, "already confirmed");
        e.deliveryConfirmed = true;
        emit DeliveryConfirmed(id_);
    }

    /// @notice Callback entry point: pay the seller after delivery.
    ///         First argument is overwritten by the proxy with the
    ///         reactive contract's address; pass it to the guard.
    function release(address reactive_, uint256 id_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        Escrow storage e = escrows[id_];
        require(e.state == State.Open && e.deliveryConfirmed, "not releasable");
        e.state = State.Released;
        (bool ok,) = e.seller.call{ value: e.amount }("");
        require(ok, "seller payment failed");
        emit Released(id_, e.seller, e.amount);
    }

    /// @notice Callback entry point: refund the buyer after the deadline.
    function refund(address reactive_, uint256 id_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        Escrow storage e = escrows[id_];
        require(e.state == State.Open && !e.deliveryConfirmed, "not refundable");
        require(block.timestamp >= e.deadline, "deadline not reached");
        e.state = State.Refunded;
        (bool ok,) = e.buyer.call{ value: e.amount }("");
        require(ok, "buyer refund failed");
        emit Refunded(id_, e.buyer, e.amount);
    }

    /// @notice Lets anyone settle this contract's callback-proxy debt
    ///         from its own balance so callbacks keep arriving.
    function coverDebt() external {
        _coverDebt();
    }
}
