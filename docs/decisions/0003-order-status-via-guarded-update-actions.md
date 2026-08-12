# ADR-0003: Order status workflow enforced by guarded update actions

## Status

Accepted

## Date

2026-08-12

## Context

An order moves through `draft → confirmed → fulfilled → paid`, and can be
`cancelled` from `draft` or `confirmed` only (ASSUMPTIONS.md #6). Each transition
does more than flip a column:

- `confirm` requires at least one line and enough stock at the order's location,
  and stamps `confirmed_at`;
- `fulfil` deducts stock through the warehouse ledger and stamps `fulfilled_at`;
- `mark_paid` stamps `paid_at`;
- `cancel` takes a `cancellation_reason` and stamps `cancelled_at`.

Other rules hang off the status too: order-header edits and all order-line
writes are rejected unless the order is still `draft`
(`FnbErp.Sales.Validations.ParentOrderIsDraft`).

The question was whether to model this with the `ash_state_machine` extension or
with ordinary Ash update actions.

## Decision

One named update action per transition on `FnbErp.Sales.Order`, each guarded by a
`FnbErp.Sales.Validations.StatusIs` validation that asserts the *current* status
before anything else runs:

```elixir
update :fulfil do
  description "Ships the order and deducts stock from the order's location."
  accept []
  require_atomic? false
  validate {Validations.StatusIs, status: :confirmed}
  change set_attribute(:status, :fulfilled)
  change set_attribute(:fulfilled_at, &DateTime.utc_now/0)
  change Changes.DeductStock
end
```

`StatusIs` accepts an atom or a list (`status: [:draft, :confirmed]` for
`cancel`), normalising it in `init/1`, and produces an
`InvalidAttribute` error naming both the current status and the allowed ones.

The status attribute itself is defensive: `writable?: false` with
`constraints: [one_of: @statuses]` and `default: :draft`, so the only way to
change it is through one of the four transition actions — the generic `:update`
action does not accept it (`accept [:order_date, :tax_rate, :notes]`) and is
itself guarded by `StatusIs, status: :draft`.

`ash_state_machine` is not a dependency.

## Alternatives Considered

### AshStateMachine extension

- **Pros:** the transition table is declared in one readable block
  (`transition :confirm, from: :draft, to: :confirmed`); guard violations produce
  a consistent `NoMatchingTransition` error; a generated state diagram; the
  obvious idiom if the graph gets complicated.
- **Cons:** another dependency and another DSL to learn for a five-state,
  five-edge graph. The transitions still need their side effects written as
  ordinary changes, so it removes the `StatusIs` validations and nothing else.
  It also changes how `status` is declared and migrated.
- **Rejected because:** the extension's value grows with the size of the state
  graph, and this graph is nearly linear. `StatusIs` is 29 lines and needs no
  dependency. If the lifecycle grows branches — partial fulfilment, returns,
  credit notes — this is the decision to revisit first.

### Free-form status column, transitions enforced in application code

- **Pros:** no validation modules at all; each caller sets whatever status it
  wants.
- **Cons:** every writer must remember the rules, and any one of them can put an
  order into an impossible state. Since AshAdmin and the JSON:API both write
  directly to actions, "application code" would have to mean "every interface".
- **Rejected because:** it moves an invariant out of the place that can actually
  enforce it. This is what `writable?: false` on `status` exists to prevent.

### Database triggers or a `CHECK` on status transitions

- **Pros:** unbypassable, even from `psql`.
- **Cons:** Postgres cannot see the previous value in a `CHECK`; this needs a
  trigger function, written and migrated by hand, duplicating rules that already
  live in the resource, with errors that surface as raw constraint violations.
- **Rejected because:** the side effects (stock deduction) have to live in
  Elixir regardless, so the trigger would be a partial second copy of the truth.

## Consequences

- Each transition is discoverable and independently callable: as a code
  interface function (`Sales.confirm_order!/1`), as an AshAdmin button, and as a
  JSON:API route (`PATCH /api/json/orders/:id/confirm`).
- Illegal transitions fail with a domain error that names the current and allowed
  statuses, not a generic validation failure.
- Every transition action sets `require_atomic? false`, because the guards and
  side effects read the record before writing. Transitions are therefore not
  atomic `UPDATE … WHERE status = …` statements, and two concurrent `fulfil`
  calls on the same order could both pass the guard. In a single-user demo this
  does not arise; a real deployment would want the transition expressed as a
  conditional update.
- The allowed-transition graph is spread across the action definitions rather
  than stated in one table — the resource `@moduledoc` and the README carry that
  summary instead, and both can drift from the code.
- Adding a state means adding it to `@statuses`, adding an action, and adding the
  `StatusIs` guard — three edits that nothing enforces the completeness of.
