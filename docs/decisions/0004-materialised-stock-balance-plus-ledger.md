# ADR-0004: Materialised stock balance plus an append-only movement ledger

## Status

Accepted

## Date

2026-08-12

## Context

Stock has to answer two different questions:

1. *How much of this product is at this location right now?* — asked on every
   order confirmation and fulfilment, and shown in the admin.
2. *Why is it that number?* — the audit question. Which receipts, sales,
   adjustments and returns got us here.

The domain also has to decide *when* stock leaves. An order is confirmed before
it ships, so there is a window in which the goods are promised but still on the
shelf.

## Decision

Two resources in `FnbErp.Warehouse`:

- **`Inventory`** — one row per (product, location) pair, carrying
  `quantity_on_hand` as a `:decimal` (precision 14, scale 3). This is the
  materialised balance and the number every reader uses.
- **`StockMovement`** — an append-only ledger row per change: signed `quantity`,
  a `reason` of `:receipt | :sale | :adjustment | :return`, a free-text
  `reference` (the order number, for a sale), and an `occurred_at`
  `create_timestamp`. It exposes only `:read` and `:create` — no update, no
  destroy. Mistakes are corrected with a compensating movement.

Every balance change goes through a single action,
`Inventory.:record_movement`, which composes:

1. `Validations.SufficientStock` — rejects a delta that would take the balance
   negative, with a readable "N on hand, M requested" error;
2. `Changes.ApplyStockDelta` — adds the signed delta to `quantity_on_hand`;
3. `Changes.RecordStockMovement` — writes the ledger row in the same
   transaction, so the ledger can never disagree with the balance.

All three run inside `FnbErp.Warehouse.apply_movement/5`, which holds a
`SELECT … FOR UPDATE` lock on the inventory row for the whole sequence, so
concurrent movements against one row queue rather than interleave. A Postgres
check constraint, `inventories_quantity_on_hand_non_negative`
(`quantity_on_hand >= 0`), declared in the resource's `check_constraints` block,
is the backstop for any future writer that skips that path.

**Deduction happens at fulfilment, not confirmation, and there is no reservation
step** (ASSUMPTIONS.md #8). Availability is checked twice:
`Validations.StockAvailable` on `confirm` as an early warning, and
`SufficientStock` on the actual movement at `fulfil` as the authoritative check.
`Changes.DeductStock` issues one movement per line inside the fulfilment
transaction, so a line that cannot be picked rolls the whole fulfilment back —
an order is never half-shipped.

## Alternatives Considered

### Derive the balance from the ledger with a `sum` aggregate

- **Pros:** one source of truth; no possibility of balance and ledger
  disagreeing; no read-modify-write, so the "insert a movement" path is
  trivially concurrent-safe.
- **Cons:** every availability check becomes an aggregate over a table that grows
  without bound, and the aggregate is what `confirm`/`fulfil` hit on every line.
  A non-negative invariant can no longer be a check constraint — a `SUM` cannot
  be constrained — so the one guarantee that currently survives a race would be
  lost.
- **Rejected because:** the check constraint is worth more than the redundancy
  is dangerous, given that `record_movement` is the only writer and it writes
  both rows in one transaction.

### Full event sourcing (ledger as the only state, projections rebuilt)

- **Pros:** complete history of the whole domain, replayable; the ledger is
  already halfway there.
- **Cons:** it would have to swallow orders too, not just stock, to be coherent —
  projections, replay tooling, versioned events. Roughly the size of the rest of
  the application.
- **Rejected because:** wildly out of proportion. The ledger already delivers
  what auditability was wanted for (ASSUMPTIONS.md #11).

### Reservation / allocation table, stock committed at confirmation

- **Pros:** what a real ERP does. Confirmed orders cannot be oversold by a later
  order, and "available to promise" becomes a real, correct number rather than
  today's on-hand snapshot.
- **Cons:** a third resource plus its lifecycle — allocate on confirm, consume on
  fulfil, release on cancel — and two stock numbers (on hand, available) that
  every reader must choose between correctly.
- **Rejected because:** it doubles the warehouse domain for a demo, and keeping
  one authoritative stock number is what makes the current code readable. This is
  the obvious next iteration, and confirming an order today only *warns* about
  availability rather than securing it.

## Consequences

- Availability is a single indexed column read. No aggregate over a growing
  table on the hot path.
- The ledger explains any balance and survives corrections, because rows are
  never mutated.
- **A confirmed order does not hold its stock.** Two orders can both confirm
  against the same units; the second one fails at `fulfil`. That is the direct
  price of skipping reservations.
- **`ApplyStockDelta` is read-modify-write, so movements against one inventory row
  are serialised by a row lock.** It reads `changeset.data.quantity_on_hand` and
  writes `on_hand + delta` rather than emitting an atomic
  `quantity_on_hand + delta` expression, because Ash cannot atomically validate a
  decimal's precision constraint against an expression. Correctness therefore
  cannot come from the statement, so it comes from the lock:
  `FnbErp.Warehouse.apply_movement/5` — the single path behind `receive_stock/4`,
  `issue_stock/4` and the fulfilment change — opens an `Ash.transaction/3`, reads
  the inventory row with `Ash.Query.lock("FOR UPDATE")`, and only then runs
  `:record_movement`, whose `after_action` ledger insert commits in that same
  transaction. A second movement against the same row blocks at the lock until
  the first commits, then re-reads the new balance, so `SufficientStock` sees the
  truth and `quantity_on_hand` always equals the sum of the ledger. The price is
  throughput: one movement at a time per (product, location), which is the right
  trade for a stock balance. The `quantity_on_hand >= 0` check constraint stays as
  a backstop for a future writer that bypasses `apply_movement/5`.
- Balance and ledger are two writes that must stay in step. They do, only because
  `record_movement` is the sole writer and does both in one transaction — a
  future code path that writes `quantity_on_hand` directly would silently break
  the audit trail.
- `FnbErp.Warehouse.available_quantity/2` returns zero when no inventory row
  exists: "never stocked here" and "none left" are the same answer to the only
  question callers ask.
