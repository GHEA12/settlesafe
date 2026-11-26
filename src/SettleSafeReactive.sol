// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/**
 * @title SettleSafeReactive — reactive contract on Reactive Lasna.
 * @notice The brain of SettleSafe. It watches the escrow contract on
 *         Base Sepolia and the network's own cron events:
 *         - `EscrowCreated`      -> remember the escrow and its deadline.
 *         - `DeliveryConfirmed`  -> call back `release` on the escrow.
 *         - `Cron100` (~2 min)   -> for every tracked escrow whose
 *           deadline has passed unsettled, call back `refund`.
 *         No keeper bot, no server: the network delivers the events and
 *         the callbacks. Fund this contract with lREACT at deployment —
 *         reactive transactions are billed to it, and a contract in debt
 *         stops receiving events.
 */
contract SettleSafeReactive is AbstractReactive {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @dev Cron events are emitted by the legacy system contract; the
    ///      subscription itself is made through the Omni SYSTEM contract.
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    uint256 internal constant ESCROW_CREATED_TOPIC_0 =
        uint256(keccak256("EscrowCreated(uint256,address,address,address,uint256,uint64)"));
    uint256 internal constant DELIVERY_CONFIRMED_TOPIC_0 = uint256(keccak256("DeliveryConfirmed(uint256)"));

    uint64 internal constant CALLBACK_GAS_LIMIT = 1000000;

    address public owner;
    address public escrow;

    struct Track {
        uint64 deadline;
        bool settled;
        bool exists;
    }

    mapping(uint256 => Track) public tracks;
    uint256[] public trackedIds;

    event Watching(address escrow);
    event Tracked(uint256 indexed id, uint64 deadline);
    event Settled(uint256 indexed id, bool released);

    constructor() payable {
        owner = msg.sender;
        SYSTEM.subscribe(
            block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Points this contract at the escrow on Base Sepolia and
    ///         subscribes to its two events. Runs after both deployments
    ///         because the escrow needs this contract's address first
    ///         (its callback sender is immutable).
    function watchEscrow(address escrow_) external onlyOwner {
        require(escrow == address(0), "already watching");
        escrow = escrow_;
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, escrow_, ESCROW_CREATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            escrow_,
            DELIVERY_CONFIRMED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit Watching(escrow_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.topic0 == ESCROW_CREATED_TOPIC_0) {
            uint256 id = log_.topic1;
            (,,, , uint64 deadline) = abi.decode(log_.data, (address, address, address, uint256, uint64));
            if (!tracks[id].exists) {
                tracks[id] = Track(deadline, false, true);
                trackedIds.push(id);
                emit Tracked(id, deadline);
            }
        } else if (log_.topic0 == DELIVERY_CONFIRMED_TOPIC_0) {
            uint256 id = log_.topic1;
            Track storage t = tracks[id];
            if (t.exists && !t.settled) {
                t.settled = true;
                _requestCallback("release(address,uint256)", id);
                emit Settled(id, true);
            }
        } else if (log_.topic0 == CRON100_TOPIC_0) {
            for (uint256 i = 0; i < trackedIds.length; i++) {
                uint256 id = trackedIds[i];
                Track storage t = tracks[id];
                if (t.exists && !t.settled && block.timestamp >= t.deadline) {
                    t.settled = true;
                    _requestCallback("refund(address,uint256)", id);
                    emit Settled(id, false);
                }
            }
        }
        // Non-matching logs fall through silently: reverting here would
        // still bill us for the reactive transaction.
    }

    function _requestCallback(string memory signature_, uint256 id_) internal {
        bytes memory payload = abi.encodeWithSignature(signature_, address(0), id_);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID, recipient: escrow, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }

    /// @notice Lets anyone settle this contract's debt from its own
    ///         balance so it keeps receiving events.
    function coverDebt() external {
        _coverDebt();
    }
}
