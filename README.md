# SettleSafe

**Escrow that settles itself.** A set-it-and-forget-it escrow for small
peer-to-peer deals (marketplace sales, freelance gigs), built for the
Reactive Omni Buildathon, "Set It and Forget It" track.

Every escrow has the same flaw: somebody has to push the final button.
The buyer forgets, the seller waits, and the money sits locked until a
person — or a keeper bot on a server — remembers to settle. SettleSafe
removes the button. The buyer funds an escrow on **Base Sepolia** naming
a seller, a courier, and a deadline. Nobody ever pushes the settlement:

- When the courier confirms delivery, that confirmation is **only an
  event**. A reactive contract on **Reactive Lasna** hears it and calls
  back across chains to release the payment to the seller.
- If the deadline passes with no delivery, the same reactive contract
  notices on the network's own **Cron100** heartbeat (~every 2 minutes)
  and calls back a refund to the buyer.

No keeper bot, no server, no one has to remember anything.

## Architecture

Two contracts, built on
[`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni)
(v0.1.0):

**`SettleSafeEscrow`** (Base Sepolia) — inherits `AbstractCallback`.
- `createEscrow(seller, courier, deadline)` (payable) stores the terms
  and emits `EscrowCreated(id, buyer, seller, courier, amount, deadline)`.
- `confirmDelivery(id)` — courier only. It deliberately does **not**
  move money; it only records the flag and emits `DeliveryConfirmed(id)`.
  Settlement belongs to the network, which is what makes the reactive
  contract load-bearing rather than decoration.
- `release(reactive, id)` / `refund(reactive, id)` — callback-only entry
  points, guarded by `onlyServiceProvider` (the caller must be the
  callback proxy) and `onlyCallbackSender` (the injected sender must be
  our reactive contract). `refund` re-checks the deadline on Base
  Sepolia itself as ground truth.

**`SettleSafeReactive`** (Lasna) — inherits `AbstractReactive`.
- The constructor subscribes to `Cron100`; `watchEscrow(escrow)`
  subscribes to the escrow's `EscrowCreated` and `DeliveryConfirmed`
  events on Base Sepolia through the Omni system contract.
- `react()` routes on the event signature: `EscrowCreated` → track
  `id → deadline`; `DeliveryConfirmed` → request a `release` callback;
  `Cron100` → for every tracked, unsettled escrow past its deadline,
  request a `refund` callback.

**Money flow (the part that matters):** the reactive contract pays for
its own reactive transactions in lREACT from its own balance (funded
with 2 lREACT at deployment, so cron ticks keep firing). Callbacks are
billed to the destination contract in Base Sepolia ETH, so the escrow
is deployed with a small ETH float and exposes `coverDebt()`.

## Deployed contracts (live)

| Contract | Chain | Address |
|---|---|---|
| SettleSafeReactive | Reactive Lasna (5318007) | [`0x8e4Ac618c16eC41a2c00C1432cE54D40c2696FD8`](https://lasna.reactscan.net/address/0x8e4Ac618c16eC41a2c00C1432cE54D40c2696FD8) |
| SettleSafeEscrow | Base Sepolia (84532) | [`0xD1650EDF9b62a8F1D6396f2Bf420dA4F0eEE6B59`](https://sepolia.basescan.org/address/0xD1650EDF9b62a8F1D6396f2Bf420dA4F0eEE6B59) |

Deployment order is forced by the escrow's immutable callback sender:
reactive contract first, then the escrow with the reactive address
baked in, then `watchEscrow(escrow)` to create the subscriptions.

## The two proof loops (both run live, 2026-11-26)

### Loop A — delivery → release (escrow #1, 0.01 ETH)

Courier confirms delivery → reactive contract reacts → callback pays
the seller. Escrow #1 ended in state **Released**; the seller's balance
was exactly 0.01 ETH.

| Step | Chain | Tx |
|---|---|---|
| Create escrow | Base Sepolia | [`0x772b4cfe…407e2fe9b`](https://sepolia.basescan.org/tx/0x772b4cfe3a90df3e24324f0e366bdc5900e4cd98d85e1dc9361d84d407e2fe9b) |
| Delivery confirmed (origin event) | Base Sepolia | [`0xf0939892…c9750af7`](https://sepolia.basescan.org/tx/0xf093989203d9fb8d550de45ba5b82c0feb5aba90cf4e79cc1ed46287c9750af7) |
| Reactive tx (release requested) | Lasna | [`0x0a4fe8dc…f0ac4b7f1`](https://lasna.reactscan.net/tx/0x0a4fe8dcdda4c04125bf10f1edbdcc83af4d3dc74cfab8ff63774e9f0ac4b7f1) |
| Callback: release | Base Sepolia | [`0x56c9c99e…3d3fe19d`](https://sepolia.basescan.org/tx/0x56c9c99e660615e791195e186d36bc2b8d97a60c60ccc18fbc168efc3d3fe19d) |

### Loop B — deadline → automatic refund (escrow #2, 0.01 ETH)

Escrow created with a 5-minute deadline; nobody confirmed delivery and
nobody touched anything afterwards. A Cron100 tick past the deadline
made the reactive contract request the refund. Escrow #2 ended in state
**Refunded**; the buyer's balance rose by exactly 0.01 ETH.

| Step | Chain | Tx |
|---|---|---|
| Create escrow | Base Sepolia | [`0xc6749b60…71b6ba1`](https://sepolia.basescan.org/tx/0xc6749b603d5ef8a0371df181aa069a76d06743240ce0687ff85b58e8b71b6ba1) |
| Cron100 tick → reactive tx (refund requested) | Lasna | [`0xc497beb8…3716ad48a7`](https://lasna.reactscan.net/tx/0xc497beb806952d30ea5d19bfa7d829a6d815ce523707e2831a2deb3716ad48a7) |
| Callback: refund | Base Sepolia | [`0xeb7a29aa…0ad69834`](https://sepolia.basescan.org/tx/0xeb7a29aa4ced33466a41a9fda1cec2d881e3a673a0db40b63ea7b6907ad69834) |

## Run the tests

```bash
export PATH=$HOME/.foundry/bin:$PATH   # if Foundry is not on PATH
forge build
forge test   # 12 tests: escrow state machine + reactive routing
```

All 12 tests pass (escrow terms storage, courier-only confirmation,
callback-only release/refund with sender checks, reactive tracking,
release-on-delivery, refund-on-cron-after-deadline, no refund before
the deadline).

## Honest simplifications (demo scale)

- Escrowed funds and the callback float share one contract balance.
- The reactive contract marks an escrow settled when it *requests* the
  callback; a failed callback would need a manual re-drive.
- The tracked-escrow list grows unboundedly — fine at demo scale; a
  production version would page or prune it.
- Deadlines use unix timestamps everywhere, never block counts (Base
  Sepolia has ~200 ms blocks).
