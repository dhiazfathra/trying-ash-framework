# Assumptions

Every judgment call made while bootstrapping this Sales Order Mini-ERP, recorded after the fact.
Architectural decisions with alternatives considered live in [docs/decisions/](docs/decisions/).

## Product / domain

| # | Assumption | Rationale |
|---|---|---|
| 1 | Single company, single currency (**IDR**), no multi-currency conversion. | F&B SME demo; multi-currency is an invoicing concern, out of scope. |
| 2 | Money stored as `:decimal` with scale 2, never float. | Avoids binary-float rounding on totals/tax. |
| 3 | Tax is a single flat **11% VAT (PPN)** applied to the order subtotal, configurable per order via `tax_rate`. | Indonesian F&B default; per-line tax classes deferred. |
| 4 | Order total = `sum(line subtotals) + tax` — no discounts, shipping, or rounding adjustments. | "Basic pricing/tax calculation" as scoped. |
| 5 | Line price is **snapshotted** from the product's `unit_price` at line creation, then editable. | Historical orders must not change when a price list changes. |
| 6 | Status workflow: `draft → confirmed → fulfilled → paid`, with `cancelled` reachable from `draft`/`confirmed` only. | Matches the scoped workflow; paid/fulfilled orders require a credit note, which is out of scope. |
| 7 | Lines are editable only while the order is `draft`. | Prevents totals drifting after stock has been committed. |
| 8 | Stock is decremented at **fulfilment**, not at confirmation; no soft reservation/allocation table. | Keeps one stock number authoritative. Reservations are the obvious next iteration. |
| 9 | Stock availability is validated at both `confirm` and `fulfil`. | Fail early on the confirm, fail safe on the fulfil. |
| 10 | One `Inventory` row per (product, warehouse) pair; multiple warehouses supported, but an order draws from a single warehouse chosen on the order header. | Multi-warehouse picking/allocation is real ERP scope, not demo scope. |
| 11 | Stock movements are recorded as an append-only `StockMovement` ledger; `quantity_on_hand` is the materialised balance. | Auditability without event-sourcing the whole domain. |
| 12 | Products carry a `category` of `:raw_material` or `:finished_good`; only `:finished_good` products are sellable. | Directly from the scope's category example. |
| 13 | No BOM / production orders / recipe explosion (raw material → finished good). | Manufacturing is a separate domain. |
| 14 | No invoicing, payments ledger, or accounting integration. `paid` is a status flag only. | Explicitly deferred; the scope said "basic". |
| 15 | Customers are soft-deleted via `active?`, never hard-deleted. | Orders must keep referential history. |
| 16 | Customer address is a flat set of string fields, not a separate address resource, and there is one address per customer (no split billing/shipping). | Single-address is the common SME case. |
| 17 | `unit_of_measure` is a fixed enum (`kg`, `g`, `l`, `ml`, `pcs`, `box`, `carton`). No UoM conversion. | Conversion factors need a UoM resource; not scoped. |
| 18 | Quantities are decimals, not integers. | F&B sells 1.5 kg. |
| 19 | Order numbers are generated as `SO-YYYYMM-NNNN` from a single global Postgres sequence, zero-padded to at least four digits (the counter never resets, so past 9999 the last segment simply grows). | Human-readable; a sequence avoids collisions between concurrent inserts without a per-month counter to reset. |
| 20 | SKU is globally unique (unique identity); customer email is unique when present. | Cheap data integrity via DB constraints. |

## Technical

| # | Assumption | Rationale |
|---|---|---|
| 21 | **No authentication and no authorisation.** `AshAuthentication` is not installed, and policies are omitted. | It is a local demo. Adding auth would double the surface area without exercising the sales-order domain. Flagged loudly in the README. |
| 22 | Single tenant. No `multitenancy` block on any resource. | See #1. |
| 23 | Ash **3.x**, Phoenix **1.8**, Elixir **1.17+** (`mix.exs` floor; bootstrapped on 1.20.3 / OTP 29, CI pinned to 1.18.4 / OTP 27.3.4). | Latest stable line; Ash 3 is what the generators target. |
| 24 | Interface = **both** AshAdmin (browsing/CRUD demo) and AshJsonApi (scriptable demo) — no bespoke LiveView CRUD screens. | See [ADR-0002](docs/decisions/0002-expose-domain-via-ash-admin-and-json-api.md). |
| 25 | Dev and test connect to Postgres on `localhost` as `postgres`/`postgres` — the Phoenix generator default, left untouched. | Works on a stock Homebrew install with trust auth, and CI can mirror it exactly. |
| 26 | Test database uses the sandbox pool; tests run with `mix test`, which auto-creates and migrates. | Phoenix default. |
| 27 | Seeds are idempotent: products and locations upsert on their identities, customers are looked up by email, orders are skipped when any order already exists, and stock is topped up to a target level rather than re-received. | Re-running a demo must not double the data or inflate stock. |
| 28 | Line `subtotal` is a **stored column** written by a change; order `subtotal` is an Ash **aggregate** over it, and `tax_amount`/`total` are expression calculations. | Keeps totals summable, filterable and sortable in SQL without a second write path. |
| 29 | Business rules live in Ash `changes`/`validations`/`actions`, not in a service layer. | The point of the exercise is idiomatic Ash. |
| 30 | Timestamps are UTC `:utc_datetime_usec`; `order_date` is a plain `:date`. | Orders are a business-day concept. |
| 31 | CI runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix ash.codegen --check` and `mix test`. No Dialyzer, no Credo. | Dialyzer's PLT build cost is not worth it at this size, and Credo would be a dep added for its own sake. `ash.codegen --check` is the valuable gate: it fails when migrations drift from the resources. |
| 32 | Docker Compose is not provided; Postgres is assumed local. | Postgres was already running locally. |
| 33 | `FnbErp.Repo.min_pg_version` is pinned to **17.0.0**, not to whatever `postgres -V` reports. | On 18+ the migration generator emits a native `uuidv7()` default that a 17 server cannot execute. |
| 34 | Stock deltas are applied read-modify-write, not with `atomic_update`, and every entry point serialises the whole read-modify-write plus ledger insert behind a `SELECT … FOR UPDATE` row lock on the inventory row. | Ash cannot atomically validate a decimal `precision` constraint against an expression, so the correctness has to come from the lock rather than from the statement. `FnbErp.Warehouse.apply_movement/5` takes the lock inside an `Ash.transaction/3`; the `quantity_on_hand >= 0` check constraint stays as a backstop for a future writer that forgets it. |
| 35 | AshAdmin is mounted only when `:dev_routes` is enabled, so it never ships in a production build. | Unauthenticated admin UI on a public port would be indefensible even for a demo. |
| 36 | Every stock change goes through the ledger, including the first receipt for a product at a location (the inventory row is created empty, then filled by a movement). | One code path, so the ledger can never disagree with the balance. |
| 37 | Order `subtotal` and `line_count` aggregates are `public? true`, exposing them over the JSON:API. | Found by the end-to-end test (`test/e2e/order_lifecycle_e2e.sh`): without this, a client can never read a total through the API at all, sparse fieldsets or not — the calculations (`tax_amount`, `total`) were already public, but they read from the aggregate, so hiding it made the whole total unreachable. |
| 38 | AshAdmin (`/admin`) is known to 500 on this stack — `ash_admin` 1.2.0 raises `KeyError: key :action_type not found` on its own root LiveView mount, with or without a `resource`/`domain` query param. Reproduced with a plain resource-less app; not caused by anything in this codebase. | Upstream issue, not patched in a vendored dependency. The JSON:API — the interface the e2e test and this app's actual usage go through — is unaffected. Flagged rather than silently left for someone to discover by clicking `/admin`. |
