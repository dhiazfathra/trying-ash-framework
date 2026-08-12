# FnbErp — Sales Order Mini-ERP

A small sales-order ERP for a food & beverage business, built on Phoenix 1.8 and
[Ash 3](https://hexdocs.pm/ash) with AshPostgres. It covers the parts of an ERP
that a wholesale F&B operation actually touches on a Tuesday: a product catalogue
of raw materials and finished goods, business customers, multiple stockholding
locations with an auditable stock ledger, and sales orders that walk a guarded
lifecycle from `draft` to `paid` — deducting stock from the right warehouse when
they ship, and computing subtotal, 11% VAT and total in SQL. The domain is
modelled entirely as Ash resources, which are the single source of truth for the
database migrations, the JSON:API and the admin UI alike; there are no
hand-written CRUD screens.

> ### ⚠️ There is no authentication and no authorisation
>
> No login, no users, no policies, no tenant boundary. Anyone who can reach this
> app can read and write every customer, order and stock balance. It is a local
> demo. **Do not deploy it or expose it to a network as it stands.** See
> [ADR-0006](docs/decisions/0006-no-authentication-or-multitenancy.md).

Two documents carry the reasoning behind the code:

- **[ASSUMPTIONS.md](ASSUMPTIONS.md)** — every judgment call made while building
  this, product and technical, in one table.
- **[docs/decisions/](docs/decisions/)** — six ADRs covering the architectural
  choices and the alternatives rejected.

## Prerequisites

| | Version | Why |
|---|---|---|
| Elixir | **1.17+** | `mix.exs` declares `elixir: "~> 1.17"`. Developed on 1.20.3 / OTP 29; CI runs 1.18.4 / OTP 27.3.4. |
| Erlang/OTP | **27+** | What the pinned Elixir builds against. |
| PostgreSQL | **17+** | See below. |

`FnbErp.Repo` pins `min_pg_version/0` to `%Version{major: 17}` deliberately —
not to whatever `postgres -V` reports locally. AshPostgres uses that version to
decide what SQL the migration generator may emit, and on 18+ it emits a native
`uuidv7()` column default that a Postgres 17 server cannot run. Pinning to 17
keeps generated migrations runnable on the lowest version we claim to support,
regardless of which server the developer happens to have installed.

Postgres is expected to be running locally on `localhost:5432` with a
`postgres`/`postgres` superuser — that is what `config/dev.exs` and
`config/test.exs` use. No Docker Compose file is provided.

## Quick start

```bash
mix deps.get                     # fetch dependencies
mix ash.setup                    # create the database and run generated migrations
mix run priv/repo/seeds.exs      # load demo locations, products, customers, stock and orders
mix phx.server                   # http://localhost:4000
```

`mix setup` does all four in one go, plus the asset build.

The seed script is idempotent — it upserts on identities and skips order seeding
if orders already exist — so re-running it is safe. It prints the seeded orders
with their computed totals, one per status.

## Commands

| Command | What it does |
|---|---|
| `mix ash.setup` | Creates the database, runs migrations, installs required Postgres extensions. |
| `mix ash.codegen <name>` | Diffs the resources against `priv/resource_snapshots/` and generates a migration named `<name>`. Run this after **any** resource change. |
| `mix ash.migrate` | Runs pending migrations. |
| `mix run priv/repo/seeds.exs` | Loads (or re-loads) the demo data. |
| `mix test` | Runs the suite. Aliased to `ash.setup --quiet` first, so it prepares the test database itself. |
| `mix format` | Formats Elixir source, including the Ash DSL section ordering configured for `:spark` in `config/config.exs`. |
| `mix precommit` | `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`. |

CI additionally runs `mix ash.codegen --check`, which fails if the checked-in
migrations and snapshots are out of date with the resources.

## URLs

With `mix phx.server` running:

| URL | What |
|---|---|
| <http://localhost:4000> | Phoenix landing page (the generated one — this app has no custom UI). |
| <http://localhost:4000/admin> | **AshAdmin** — browse and edit every resource, and run the order lifecycle actions. Mounted behind `:dev_routes`, so it exists in dev and test only. |
| <http://localhost:4000/api/json> | **JSON:API** for all three domains. |
| <http://localhost:4000/api/json/open_api> | Generated OpenAPI document. |
| <http://localhost:4000/api/json/swaggerui> | SwaggerUI over that document. |
| <http://localhost:4000/dev/dashboard> | Phoenix LiveDashboard (`:dev_routes`). |
| <http://localhost:4000/dev/mailbox> | Swoosh mailbox preview (`:dev_routes`). Nothing in this app sends mail. |

## Domain model

Three Ash domains, seven resources.

### `FnbErp.Catalog` — what we sell and who we sell it to

**`Product`** (`products`) — anything bought or sold.

| Attribute | Notes |
|---|---|
| `sku` | Globally unique (`unique_sku` identity); `:create` upserts on it. |
| `name`, `description` | |
| `unit_price` | `:decimal`, scale 2. Snapshotted onto order lines at creation. |
| `unit_of_measure` | `:kg \| :g \| :l \| :ml \| :pcs \| :box \| :carton`, default `:pcs`. No conversion between units. |
| `category` | `:raw_material \| :finished_good`, default `:finished_good`. |
| `active?` | Products are deactivated, not deleted. |

Only **active finished goods** can be put on an order line — enforced by
`Validations.ProductIsSellable`. The `:sellable` read action filters to exactly
that set.

**`Customer`** (`customers`) — a business that buys from us.

| Attribute | Notes |
|---|---|
| `name`, `contact_name`, `email`, `phone` | `email` is format-validated and unique when present (`nils_distinct?: true`). |
| `address_line1/2`, `city`, `province`, `postal_code`, `country` | Flat fields, one address, `country` defaults to `"ID"`. |
| `active?` | Customers are deactivated (`:deactivate` / `:activate`), never destroyed — orders reference them forever. |

### `FnbErp.Warehouse` — where stock is, how much there is, and every movement

**`Location`** (`locations`) — a warehouse, cold room or outlet store.
`code` is unique and `:create` upserts on it; also `name`, `address`, `active?`.

**`Inventory`** (`inventories`) — the balance of one product at one location.
One row per (`product_id`, `location_id`) pair (`unique_product_location`
identity), carrying `quantity_on_hand` (`:decimal`, scale 3). A Postgres check
constraint enforces `quantity_on_hand >= 0`. The only action that changes the
balance is `:record_movement`, which takes a signed `quantity`, a `reason` and an
optional `reference`, validates sufficiency, applies the delta and writes the
ledger row in the same transaction.

**`StockMovement`** (`stock_movements`) — append-only ledger. Signed `quantity`
(positive in, negative out), `reason` of `:receipt | :sale | :adjustment |
:return`, free-text `reference` (the order number, for a sale), and
`occurred_at`. Exposes only `:read` and `:create` — rows are never updated or
deleted; a mistake is corrected with a compensating movement.

Domain helpers: `available_quantity/2` (returns zero when there is no inventory
row), `receive_stock/4`, `issue_stock/4`.

### `FnbErp.Sales` — orders and their lifecycle

**`Order`** (`orders`) — the order header.

| Attribute | Notes |
|---|---|
| `order_number` | `SO-YYYYMM-NNNN`, generated from a Postgres sequence (`order_number_seq`) so concurrent inserts cannot collide. Not writable. |
| `status` | `:draft \| :confirmed \| :fulfilled \| :paid \| :cancelled`. Not writable — only the transition actions move it. |
| `order_date` | `:date`, defaults to today. |
| `tax_rate` | `:decimal`, scale 4, defaults to `0.11` (11% VAT / PPN), validated to be between 0 and 1. |
| `notes`, `cancellation_reason` | |
| `confirmed_at`, `fulfilled_at`, `paid_at`, `cancelled_at` | Stamped by the matching transition. |
| `customer_id` | Required. |
| `location_id` | Required — the single warehouse the whole order is picked from. |

Computed, not stored: `subtotal` (a `sum` aggregate over the lines'
`subtotal`), `line_count` (a `count`), and the expression calculations
`tax_amount` (`subtotal * tax_rate`) and `total`
(`subtotal + subtotal * tax_rate`). All four are SQL-side, so they can be
loaded, filtered and sorted — but they must be *asked for* (`Ash.load!/2`, or
`fields[order]=` over the API).

**`OrderLine`** (`order_lines`) — one product line, unique per
(`order_id`, `product_id`).

| Attribute | Notes |
|---|---|
| `quantity` | `:decimal`, scale 3, must be greater than zero. |
| `unit_price` | Snapshotted from the product's `unit_price` when not supplied, so repricing the catalogue never rewrites order history. Must not be negative. |
| `subtotal` | `quantity × unit_price`, rounded to 2dp and **stored** on write. Not writable directly. |

Lines can only be created, updated or destroyed while the parent order is
`draft`.

## Order status workflow

```
                  ┌──────────┐
                  │  draft   │ ← created here; lines editable only here
                  └────┬─────┘
                       │ confirm    (needs ≥1 line + stock available)
                  ┌────▼─────┐
                  │confirmed │
                  └────┬─────┘
                       │ fulfil     (deducts stock from the order's location)
                  ┌────▼─────┐
                  │fulfilled │
                  └────┬─────┘
                       │ mark_paid
                  ┌────▼─────┐
                  │   paid   │  terminal
                  └──────────┘

  draft ─┐
         ├─ cancel ──▶ cancelled   terminal
  confirmed ─┘
```

| Action | From | To | Also does |
|---|---|---|---|
| `confirm` | `draft` | `confirmed` | Requires at least one line (`HasLines`) and enough stock at the order's location (`StockAvailable`). Stamps `confirmed_at`. |
| `fulfil` | `confirmed` | `fulfilled` | Issues one `:sale` stock movement per line from the order's location, referenced by order number, inside the same transaction — so a line that cannot be picked rolls the whole fulfilment back. Stamps `fulfilled_at`. |
| `mark_paid` | `fulfilled` | `paid` | Stamps `paid_at`. Status flag only — there is no payments ledger. |
| `cancel` | `draft`, `confirmed` | `cancelled` | Accepts `cancellation_reason`. Stamps `cancelled_at`. |
| `update` (header) | `draft` only | — | Accepts `order_date`, `tax_rate`, `notes`. |

Every transition is guarded by `Validations.StatusIs`, which rejects the call
with an error naming the current status and the allowed ones. Nothing else can
write `status`. Note that stock is checked at `confirm` but **not reserved** —
it is only deducted at `fulfil`, so two orders can both confirm against the same
units and the second will fail to ship. See
[ADR-0003](docs/decisions/0003-order-status-via-guarded-update-actions.md) and
[ADR-0004](docs/decisions/0004-materialised-stock-balance-plus-ledger.md).

## JSON:API examples

Every request and response uses `application/vnd.api+json`. Resource ids are
UUIDv7. Foreign keys go in `data.attributes` (`customer_id`, `location_id`,
`order_id`, `product_id`) — they are not exposed as JSON:API relationship
linkage for writes.

Routes exposed per resource:

| Resource | Routes |
|---|---|
| `products` | `GET /`, `GET /:id`, `POST /`, `PATCH /:id` |
| `customers` | `GET /`, `GET /:id`, `POST /`, `PATCH /:id` |
| `locations` | `GET /`, `GET /:id`, `POST /`, `PATCH /:id` |
| `inventories` | `GET /`, `GET /:id` |
| `stock_movements` | `GET /`, `GET /:id` |
| `orders` | `GET /`, `GET /:id`, `POST /`, `PATCH /:id`, and `PATCH /:id/confirm`, `PATCH /:id/fulfil`, `PATCH /:id/mark_paid`, `PATCH /:id/cancel` |
| `order_lines` | `GET /`, `GET /:id`, `POST /`, `PATCH /:id`, `DELETE /:id` |

The four lifecycle routes are `PATCH`, not `POST`.

**List products, and find a customer and a location to order with:**

```bash
curl -s http://localhost:4000/api/json/products \
  -H 'Accept: application/vnd.api+json'

curl -s http://localhost:4000/api/json/customers \
  -H 'Accept: application/vnd.api+json'

curl -s http://localhost:4000/api/json/locations \
  -H 'Accept: application/vnd.api+json'
```

**Create a draft order** (substitute real UUIDs from the calls above):

```bash
curl -s -X POST http://localhost:4000/api/json/orders \
  -H 'Content-Type: application/vnd.api+json' \
  -H 'Accept: application/vnd.api+json' \
  -d '{
    "data": {
      "type": "order",
      "attributes": {
        "customer_id": "01919c2e-0000-7000-8000-000000000001",
        "location_id":  "01919c2e-0000-7000-8000-000000000002",
        "notes": "Kirim pagi sebelum jam 09.00"
      }
    }
  }'
```

**Add a line.** Omit `unit_price` to snapshot the product's current price:

```bash
curl -s -X POST http://localhost:4000/api/json/order_lines \
  -H 'Content-Type: application/vnd.api+json' \
  -H 'Accept: application/vnd.api+json' \
  -d '{
    "data": {
      "type": "order_line",
      "attributes": {
        "order_id":   "01919c2e-0000-7000-8000-000000000003",
        "product_id": "01919c2e-0000-7000-8000-000000000004",
        "quantity": "48"
      }
    }
  }'
```

**Confirm it.** The lifecycle actions accept no attributes, but JSON:API still
wants a body:

```bash
curl -s -X PATCH http://localhost:4000/api/json/orders/01919c2e-0000-7000-8000-000000000003/confirm \
  -H 'Content-Type: application/vnd.api+json' \
  -H 'Accept: application/vnd.api+json' \
  -d '{"data": {"type": "order", "attributes": {}}}'
```

`fulfil` and `mark_paid` take the same shape. `cancel` takes a reason:

```bash
curl -s -X PATCH http://localhost:4000/api/json/orders/01919c2e-0000-7000-8000-000000000003/cancel \
  -H 'Content-Type: application/vnd.api+json' \
  -H 'Accept: application/vnd.api+json' \
  -d '{"data": {"type": "order", "attributes": {"cancellation_reason": "Event dibatalkan karena cuaca"}}}'
```

**Read an order with its totals and lines.** Totals are calculations and
aggregates, so they only appear when requested:

```bash
curl -s -G http://localhost:4000/api/json/orders/01919c2e-0000-7000-8000-000000000003 \
  -H 'Accept: application/vnd.api+json' \
  --data-urlencode 'fields[order]=order_number,status,subtotal,tax_amount,total,line_count' \
  --data-urlencode 'include=lines'
```

**Filter orders by status:**

```bash
curl -s -G http://localhost:4000/api/json/orders \
  -H 'Accept: application/vnd.api+json' \
  --data-urlencode 'filter[status]=confirmed'
```

A rejected transition comes back as a JSON:API error naming the problem — try
confirming an order twice, or fulfilling one with more stock than the location
holds.

## What's built vs deferred

**Built**

- Three Ash domains, seven resources, generated migrations with checked-in
  resource snapshots.
- Product catalogue with SKU identity, unit of measure, raw-material vs
  finished-good categories, and sellability enforced on order lines.
- Business customers with soft deactivation and a validated unique email.
- Multiple stock locations; per-(product, location) balances; append-only stock
  movement ledger with `:receipt | :sale | :adjustment | :return` reasons; a
  non-negative check constraint in the database.
- Sales orders with sequence-generated human-readable numbers, price-snapshotted
  lines, stored line subtotals, and SQL-side subtotal / tax / total.
- Five-state guarded lifecycle with stock checked at confirm and deducted at
  fulfil, transactionally per order.
- AshAdmin UI, JSON:API for all three domains, OpenAPI document and SwaggerUI.
- Idempotent seed script with realistic Indonesian F&B data across every order
  status.
- GitHub Actions CI: format check, warnings-as-errors compile,
  `mix ash.codegen --check`, and the test suite against `postgres:17`.

**Deferred** — and why, in [ASSUMPTIONS.md](ASSUMPTIONS.md)

- **Authentication, authorisation, multitenancy.** None. See the warning at the
  top and [ADR-0006](docs/decisions/0006-no-authentication-or-multitenancy.md).
- **Stock reservation / allocation.** Confirming an order does not hold its
  stock; only fulfilment moves it.
- **Concurrency hardening.** The stock delta is read-modify-write, so concurrent
  movements on one inventory row are last-write-wins (the check constraint still
  prevents negative stock). Lifecycle transitions are non-atomic for the same
  reason. Documented in
  [ADR-0004](docs/decisions/0004-materialised-stock-balance-plus-ledger.md).
- **Invoicing, payments, accounting.** `paid` is a status flag; there is no
  payment record.
- **Discounts, shipping charges, rounding adjustments, per-line tax classes.**
  One flat rate per order.
- **Multi-currency.** Single company, IDR only.
- **BOM / production orders / recipe explosion.** Raw materials exist as a
  category, but nothing turns them into finished goods.
- **Multi-warehouse picking.** An order draws from one location chosen on the
  header.
- **Unit-of-measure conversion.** The enum is fixed and no factors are stored.
- **Purchasing / suppliers / goods receipt.** Stock arrives via a `:receipt`
  movement with a free-text reference.
- **Split billing/shipping addresses.** One flat address per customer.
- **Custom LiveView screens.** AshAdmin is the UI; `ash_phoenix` is installed
  for when that changes.
- **Dialyzer in CI.** Not worth the PLT build cost at this size.
