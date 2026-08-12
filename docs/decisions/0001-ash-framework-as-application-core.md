# ADR-0001: Ash Framework + AshPostgres as the application core

## Status

Accepted

## Date

2026-08-12

## Context

`FnbErp` is a sales-order mini-ERP for a food & beverage business: products,
customers, warehouses, stock, and orders with a status lifecycle. Three
interfaces have to agree on the same rules — a browsable admin UI, a scriptable
HTTP API, and the seed script — and the schema has to be kept in step with the
domain as it changes.

Phoenix 1.8 gives us the web layer either way. The open question was what sits
underneath it: hand-written contexts over Ecto schemas, or a declarative
resource layer.

The rules that need one authoritative home are not trivial:

- order numbering (`SO-YYYYMM-NNNN` from a Postgres sequence),
- line pricing snapshots,
- order totals (subtotal, tax, total),
- a five-state order lifecycle with per-transition guards,
- stock sufficiency checks and an append-only movement ledger.

## Decision

Model the domain as Ash 3 resources with `AshPostgres.DataLayer`, grouped into
three `Ash.Domain` modules — `FnbErp.Catalog`, `FnbErp.Sales`,
`FnbErp.Warehouse` — registered in `config/config.exs` under `:ash_domains`.

Concretely:

- Each resource declares its own `postgres` block (table, `references`,
  `check_constraints`, `custom_statements`). Migrations are **generated** from
  the resources by `mix ash.codegen`, with resource snapshots checked in under
  `priv/resource_snapshots/`.
- Business rules live in Ash actions, `Ash.Resource.Change` and
  `Ash.Resource.Validation` modules (`lib/fnb_erp/sales/changes.ex`,
  `lib/fnb_erp/sales/validations.ex`, `lib/fnb_erp/warehouse/changes/`,
  `lib/fnb_erp/warehouse/validations/`) — not in a service layer.
- Each domain exposes a code interface (`define :create_order`,
  `define :confirm_order`, …) so Elixir callers, the seed script and tests use
  the same entry points the HTTP layer does.
- `FnbErp.Repo` is an `AshPostgres.Repo`.

The two places where we deliberately step outside the resource DSL are a raw
`nextval('order_number_seq')` query for order numbers, and the small
`FnbErp.Warehouse` domain-module helpers (`available_quantity/2`,
`receive_stock/4`, `issue_stock/4`) that wrap the inventory lookup callers keep
repeating.

## Alternatives Considered

### Plain Phoenix contexts + Ecto schemas

- **Pros:** no framework to learn; complete control over queries; the
  best-documented path in the Phoenix community; easy for any Elixir developer
  to read.
- **Cons:** every rule needs a hand-written home, and each interface (admin,
  API, seeds) re-implements its own validation and changeset plumbing.
  Migrations are written by hand and drift from the schema silently. There is no
  free admin UI or JSON:API surface.
- **Rejected because:** with three interfaces over the same rules, the
  duplication is the whole cost of the project, and a declarative resource layer
  removes it. Trying Ash was also an explicit goal of the exercise.

### Absinthe-first design (GraphQL schema as the source of truth)

- **Pros:** one strongly-typed contract; excellent tooling; clients ask for
  exactly the fields they want.
- **Cons:** the schema describes the *transport*, not the domain — resolvers
  still need a domain layer behind them, so this is additive rather than
  alternative. It also buys nothing for the admin UI or for migrations.
- **Rejected because:** it solves a problem we do not have (no client with
  bespoke query needs) and leaves the actual problem — one authoritative rule
  set — untouched.

## Consequences

- **Resources are the single source of truth.** Adding an attribute to
  `FnbErp.Sales.Order` updates the JSON:API payload, the AshAdmin form, and —
  after `mix ash.codegen` — the migration. Nothing is edited in three places.
- **Migrations are generated, not written.** `mix ash.codegen <name>` diffs the
  resources against `priv/resource_snapshots/` and emits a migration; CI runs
  `mix ash.codegen --check` so a resource change without a regenerated
  migration fails the build.
- **Rules are testable in isolation.** Each change/validation is a module with a
  single callback.
- **The framework is now load-bearing.** Anything Ash does not express directly
  (the order-number sequence, the read-modify-write stock delta) needs an escape
  hatch, and those escape hatches carry their own caveats — see
  [ADR-0004](0004-materialised-stock-balance-plus-ledger.md).
- **Ash's learning curve is on the reader.** Someone who knows Phoenix but not
  Ash cannot follow `lib/fnb_erp/` by pattern-matching on Ecto knowledge alone.
