# ADR-0005: Decimal money and quantities, stored line subtotals, aggregate order totals

## Status

Accepted

## Date

2026-08-12

## Context

Prices are in IDR, a currency whose everyday amounts run to hundreds of
thousands per unit (`165000.00` for a kilo of beans in the seed data).
Quantities are not whole numbers — F&B sells 1.5 kg (ASSUMPTIONS.md #18). Tax is
a flat 11% VAT held as a rate per order, so totals involve a multiplication that
must round predictably.

Two related choices follow: what type holds the numbers, and where the arithmetic
happens — at write time into a column, or at read time.

Orders also need to be listed and sorted by value in both the admin and the API,
which constrains where totals can live.

## Decision

**Types.** Every money and quantity attribute is `:decimal` with an explicit
precision/scale constraint. Never a float, never an integer of minor units:

| Attribute | Type | Constraints |
|---|---|---|
| `Product.unit_price` | `:decimal` | precision 14, scale 2 |
| `OrderLine.quantity` | `:decimal` | precision 14, scale 3 |
| `OrderLine.unit_price` | `:decimal` | precision 14, scale 2 |
| `OrderLine.subtotal` | `:decimal` | precision 16, scale 2 |
| `Order.tax_rate` | `:decimal` | precision 5, scale 4 |
| `Inventory.quantity_on_hand` | `:decimal` | precision 14, scale 3 |
| `StockMovement.quantity` | `:decimal` | precision 14, scale 3 |

`Order.tax_rate` defaults to `Decimal.new("0.11")` and is validated to be
between 0 and 1.

**Line subtotal is stored on write.** `FnbErp.Sales.Changes.PriceLine` runs in a
`before_action` hook on the line's `:create` and `:update` actions. It snapshots
`unit_price` from the product when none was given, then force-changes
`subtotal` to `Decimal.mult(quantity, unit_price) |> Decimal.round(2)`. The
attribute is `writable?: false` with a default of zero, so the only thing that
can set it is that change.

**Order totals are computed in SQL, not stored.** On `FnbErp.Sales.Order`:

```elixir
aggregates do
  sum :subtotal, :lines, :subtotal, default: Decimal.new(0)
  count :line_count, :lines
end

calculations do
  calculate :tax_amount, :decimal, expr(subtotal * tax_rate), public?: true
  calculate :total, :decimal, expr(subtotal + subtotal * tax_rate), public?: true
end
```

Because the order's `subtotal` is an Ash aggregate and `tax_amount`/`total` are
expression calculations over it, all three are pushed into SQL and can be
loaded, filtered and sorted. Nothing about an order's value is denormalised onto
the `orders` table.

The split is deliberate: the line subtotal has to be *frozen* (it is the
snapshot of a price at a point in time, per ASSUMPTIONS.md #5), whereas the order
total is a pure function of its lines and never needs freezing.

## Alternatives Considered

### Integer minor units (store rupiah, or cents, as `:integer`)

- **Pros:** exact by construction; no decimal library at the boundary; the usual
  advice for money.
- **Cons:** IDR's minor unit is effectively unused, so "cents" would be a
  fiction, and every read and write needs a scaling conversion that some caller
  will eventually forget. Quantities still cannot be integers (1.5 kg), so the
  codebase would carry two numeric conventions. `Decimal` in Elixir and
  `numeric` in Postgres are already exact.
- **Rejected because:** it trades a real correctness guarantee we already have
  for a scaling bug waiting to happen, and it does not solve quantities at all.

### Floats

- **Pros:** none that matter here.
- **Cons:** binary floats cannot represent `0.11` exactly; totals drift.
- **Rejected because:** it is wrong for money. Stated explicitly as
  ASSUMPTIONS.md #2 so nobody re-litigates it.

### Line subtotal as a runtime-only calculation

- **Pros:** no chance of a stored subtotal disagreeing with
  `quantity × unit_price`; one less `force_change_attribute`.
- **Cons:** the order's `subtotal` is a `sum` aggregate over the *column*
  `order_lines.subtotal`. Without that column, summing lines means an expression
  aggregate or an in-memory fold, and filtering or sorting orders by value gets
  harder or impossible.
- **Rejected because:** the aggregate is the reason the column exists. Keeping it
  written by exactly one change module (`PriceLine`, on both `:create` and
  `:update`, with `writable?: false` blocking anything else) bounds the risk of
  disagreement.

### Storing `tax_amount` and `total` on the order as denormalised columns

- **Pros:** a single-row read gives the total, with no join; totals are immune to
  a later line change.
- **Cons:** three numbers to keep in step with the lines, refreshed from a change
  on the line resource that reaches up to its parent — the exact kind of
  bidirectional write that goes stale. Lines are only writable while the order is
  `draft` (ASSUMPTIONS.md #7), so nothing needs freezing anyway.
- **Rejected because:** the aggregate is already SQL-side and therefore already
  filterable and sortable, which was the only reason to denormalise.

### Postgres generated columns (`GENERATED ALWAYS AS`)

- **Pros:** the database guarantees the value; impossible to get out of step.
- **Cons:** a generated column may only reference the same row, so the order's
  total — which depends on its lines — is out of reach. Even for the line
  subtotal it would mean hand-written SQL outside the resource DSL, breaking the
  generated-migration workflow of
  [ADR-0001](0001-ash-framework-as-application-core.md).
- **Rejected because:** it cannot express the case that actually matters, and it
  costs the codegen guarantee for the case it can.

## Consequences

- Money arithmetic is exact end to end: `Decimal` in Elixir, `numeric` in
  Postgres.
- `subtotal`, `tax_amount`, `total` and `line_count` are loadable, filterable and
  sortable on orders — the seed script's final report just does
  `Ash.load!([:subtotal, :tax_amount, :total])`.
- Totals can never disagree with the lines, because they are not stored.
- **Order totals are not visible without loading them.** They are absent from a
  plain read; `config/config.exs` sets
  `show_public_calculations_when_loaded?: false` for AshJsonApi, so API clients
  must ask for them explicitly.
- Rounding happens once, on the line subtotal (`Decimal.round(2)`).
  `tax_amount` and `total` are *not* rounded — they are computed in Postgres from
  a scale-2 subtotal and a scale-4 rate, so a total can carry more than two
  decimal places. Presentation rounding is the caller's problem, and there is no
  invoice rounding adjustment (ASSUMPTIONS.md #4).
- Precision/scale constraints force `require_atomic? false` in places — notably
  `Inventory.:record_movement`, whose delta cannot be applied as an atomic
  expression for exactly this reason. The read-modify-write that replaces it is
  made safe by a `SELECT … FOR UPDATE` lock on the inventory row rather than by
  the statement (ASSUMPTIONS.md #34); order status transitions are serialised the
  same way (`FnbErp.Sales.Changes.LockOrder`, see
  [ADR-0003](0003-order-status-via-guarded-update-actions.md)). See also
  [ADR-0004](0004-materialised-stock-balance-plus-ledger.md).
- A price change on a product does not rewrite existing order lines; the line
  keeps the price it was created with.
