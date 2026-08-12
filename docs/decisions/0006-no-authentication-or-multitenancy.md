# ADR-0006: No authentication, authorisation or multitenancy

## Status

Accepted

## Date

2026-08-12

## Context

`FnbErp` is a local demonstration of an Ash-based sales-order domain. The point
of the exercise is the domain: products, stock, orders and their lifecycle. It
runs on one developer machine against a local Postgres.

Adding identity to it is not a small addition. A realistic version would need
users and sessions (`ash_authentication` plus `ash_authentication_phoenix`),
`policies` blocks on all seven resources, an actor threaded through every code
interface call, seeds and tests, plus something protecting the admin UI. That is
comparable in size to the sales domain itself.

## Decision

Ship with none of it.

- `ash_authentication` is not a dependency. There are no users, no sessions, no
  login.
- No resource declares a `policies` block. Ash's authorizer therefore has nothing
  to enforce, and no `actor` is passed anywhere.
- No resource declares a `multitenancy` block. Single company, single currency
  (ASSUMPTIONS.md #1, #22).
- `AshAdmin` is mounted at `/admin` inside the
  `Application.compile_env(:fnb_erp, :dev_routes)` guard, so it is compiled into
  dev and test only. That is a build-time flag, not a security control.
- The JSON:API at `/api/json` is **not** behind that guard and has no protection
  of any kind.

This is recorded loudly in ASSUMPTIONS.md #21 and at the top of the README.

## Consequences — read this one first

> **This application must not be deployed or exposed to a network as it stands.**
> Anyone who can reach it has unauthenticated read and write access to every
> customer, product, order and stock balance — creating orders, cancelling them,
> and moving stock. There is no login, no permission check, no audit of *who* did
> anything, and no tenant boundary. The `StockMovement` ledger records what
> changed and why, never who.

Everything else follows from that:

- Every code interface call is unauthorised by default; adding policies later
  will break every call site that does not pass an `actor`, which is the correct
  failure mode but a wide one.
- Resources carry no ownership or tenant column, so introducing multitenancy
  means a migration on every table, not a config change.
- `config/dev.exs` and `config/test.exs` contain a hard-coded
  `postgres`/`postgres` credential pair and `config/dev.exs` a committed
  `secret_key_base`. Fine for a throwaway local database; another reason this
  tree is not deployable.
- `/admin` vanishing in `MIX_ENV=prod` is a side effect of the `:dev_routes`
  guard, not a considered production posture. `/api/json` does not vanish.

## Alternatives Considered

### AshAuthentication + Ash policies

- **Pros:** the correct answer for anything real. Password or magic-link
  strategies out of the box, an actor available to every action, and `policies`
  blocks that express authorisation next to the data they protect — the same
  single-source-of-truth argument as
  [ADR-0001](0001-ash-framework-as-application-core.md). Would also give the
  ledger a "who".
- **Cons:** roughly doubles the surface area — a `User` resource, sign-in
  routes and LiveViews, session plumbing in the router, policies on seven
  resources, an actor threaded through seeds and tests, and an actor for
  AshAdmin.
- **Rejected because:** none of that work exercises the sales-order domain, which
  is the thing being demonstrated. It is the first thing to add before this goes
  anywhere near a network.

### HTTP basic auth in front of everything (`Plug.BasicAuth`)

- **Pros:** about five lines in the router; keeps casual traffic out of `/admin`
  and `/api/json`.
- **Cons:** buys no *authorisation* — one shared credential, every caller
  omnipotent, still no actor and still no "who" in the audit trail. Over plain
  HTTP the credential is sent in the clear. Its real danger is that it looks like
  security, which invites deploying the thing.
- **Rejected because:** it would blur an honest "this has no auth" into a
  misleading "this has some auth". A hard stop is safer than a weak lock.

### Read-only public API, writes only via AshAdmin

- **Pros:** shrinks the unauthenticated blast radius to disclosure.
- **Cons:** the scriptable write demo — confirm, fulfil, mark paid from `curl` —
  is precisely what the JSON:API is there for
  ([ADR-0002](0002-expose-domain-via-ash-admin-and-json-api.md)). And customer
  data would still leak.
- **Rejected because:** it removes the API's purpose without making the app
  deployable.
