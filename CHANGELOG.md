# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-12

First cut of the sales-order mini-ERP. See
[docs/decisions/](docs/decisions/) for the architectural decisions and
[ASSUMPTIONS.md](ASSUMPTIONS.md) for the judgment calls.

### Added

- Phoenix 1.8 application on Ash 3 with AshPostgres, split into three domains:
  `FnbErp.Catalog`, `FnbErp.Sales` and `FnbErp.Warehouse`.
- `Catalog.Product` — SKU as a unique identity with upsert-on-create, decimal
  `unit_price`, fixed unit-of-measure enum, `:raw_material` / `:finished_good`
  category, soft deactivation, and a `:sellable` read action for active finished
  goods.
- `Catalog.Customer` — flat single address defaulting to country `ID`,
  format-validated email unique when present, `:activate` / `:deactivate`
  instead of destroy.
- `Warehouse.Location` — stockholding places, unique `code` with
  upsert-on-create.
- `Warehouse.Inventory` — one `quantity_on_hand` balance per (product,
  location), changed only through the `:record_movement` action, serialised by a
  `SELECT … FOR UPDATE` lock on the row, with a `quantity_on_hand >= 0` Postgres
  check constraint as a backstop.
- `Warehouse.StockMovement` — append-only ledger with signed quantities,
  `:receipt` / `:sale` / `:adjustment` / `:return` reasons, free-text reference
  and `occurred_at`; read and create only, indexed on `inventory_id`.
- `FnbErp.Warehouse` helpers `available_quantity/2`, `receive_stock/4` and
  `issue_stock/4`. Both movement helpers take a positive magnitude and reject
  zero or negative quantities, so a ledger reason can never contradict the sign
  of the balance change.
- `Sales.Order` — `SO-YYYYMM-NNNN` numbers from a Postgres sequence, per-order
  `tax_rate` defaulting to 11% VAT, required customer and single pick location,
  transition timestamps, `subtotal` and `line_count` aggregates, and
  `tax_amount` / `total` expression calculations.
- `Sales.OrderLine` — unique product per order, quantity and price validations,
  `unit_price` snapshotted from the product at creation, `subtotal` computed and
  stored on write, and writes rejected unless the parent order is `draft`.
- Guarded order lifecycle `draft → confirmed → fulfilled → paid` with `cancel`
  from `draft` or `confirmed`: `confirm` requires lines and available stock,
  `fulfil` deducts stock per line transactionally from the order's location,
  `mark_paid` and `cancel` stamp their timestamps. Enforced by a `StatusIs`
  validation with `status` non-writable.
- Reusable Ash changes and validations: `GenerateOrderNumber`, `PriceLine`,
  `DeductStock`, `ApplyStockDelta`, `RecordStockMovement`, `StatusIs`,
  `HasLines`, `StockAvailable`, `ParentOrderIsDraft`, `ProductIsSellable`,
  `SufficientStock`.
- Code interfaces on all three domains, so Elixir callers, seeds and tests use
  the same entry points as the HTTP layer.
- AshAdmin mounted at `/admin` behind `:dev_routes`.
- AshJsonApi at `/api/json` for all three domains, with the generated OpenAPI
  document at `/api/json/open_api` and SwaggerUI at `/api/json/swaggerui`;
  `application/vnd.api+json` registered with `:mime`.
- Generated initial migrations plus checked-in resource snapshots, and
  `FnbErp.Repo.min_pg_version/0` pinned to 17 so generated SQL stays runnable
  there.
- Idempotent seed script (`priv/repo/seeds.exs`) with Indonesian F&B locations,
  products, customers, stock receipts and one order in each status.
- `ASSUMPTIONS.md` and six ADRs under `docs/decisions/`.
- GitHub Actions CI: `postgres:17` service, format check,
  `mix compile --warnings-as-errors`, `mix ash.codegen --check` and `mix test`,
  with deps and `_build` cached on `mix.lock`.

### Known limitations

- **No authentication, authorisation or multitenancy.** Not deployable as it
  stands — see
  [ADR-0006](docs/decisions/0006-no-authentication-or-multitenancy.md).
- No stock reservation: confirming an order checks availability but does not
  hold it.
- Stock deltas are read-modify-write, so every movement takes a `FOR UPDATE` lock
  on the inventory row; throughput on a single hot (product, location) pair is
  therefore one movement at a time.
- No invoicing or payments ledger — `paid` is a status flag.
- No discounts, shipping charges, per-line tax classes, multi-currency, BOM or
  unit-of-measure conversion.
