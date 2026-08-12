# Architecture Decision Records

Each ADR records one decision, the alternatives weighed against it, and what we
now live with. Format: `# ADR-NNNN: Title`, then Status, Date, Context, Decision,
Alternatives Considered, Consequences.

Smaller judgment calls without alternatives worth writing up live in
[ASSUMPTIONS.md](../../ASSUMPTIONS.md).

| ADR | Decision |
|---|---|
| [0001](0001-ash-framework-as-application-core.md) | Ash Framework + AshPostgres as the application core — resources are the single source of truth for API, admin and migrations. |
| [0002](0002-expose-domain-via-ash-admin-and-json-api.md) | Expose the domain via AshAdmin (`/admin`, dev only) and AshJsonApi (`/api/json`) rather than hand-written LiveView CRUD. |
| [0003](0003-order-status-via-guarded-update-actions.md) | Order status workflow enforced by guarded update actions (`confirm`, `fulfil`, `mark_paid`, `cancel`) instead of the AshStateMachine extension. |
| [0004](0004-materialised-stock-balance-plus-ledger.md) | Stock as a materialised `quantity_on_hand` balance plus an append-only `StockMovement` ledger, deducted at fulfilment with no reservation step. |
| [0005](0005-decimal-money-stored-line-subtotals-aggregate-totals.md) | Money and quantities as `:decimal`; line `subtotal` stored on write; order totals as an Ash aggregate and expression calculations. |
| [0006](0006-no-authentication-or-multitenancy.md) | No authentication, authorisation or multitenancy — **not deployable as it stands**. |
