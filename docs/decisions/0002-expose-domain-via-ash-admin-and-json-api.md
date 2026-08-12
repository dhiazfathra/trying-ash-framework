# ADR-0002: Expose the domain via AshAdmin and AshJsonApi, not hand-written LiveView CRUD

## Status

Accepted

## Date

2026-08-12

## Context

The domain needs two kinds of access to be demonstrable:

1. **Human** — click through customers, products, stock and orders; run the
   order lifecycle by hand; see what the totals came out as.
2. **Machine** — drive the same actions from `curl` or a test script, with a
   discoverable contract.

Building either by hand means writing forms, tables, pagination, filtering,
error rendering and nested-resource navigation for seven resources. None of that
is the point of the exercise, and none of it is domain logic.

## Decision

Expose the resources through two generated interfaces and write no bespoke CRUD
screens.

**AshAdmin** — mounted in `lib/fnb_erp_web/router.ex` inside a
`Application.compile_env(:fnb_erp, :dev_routes)` guard:

```elixir
scope "/admin" do
  pipe_through :browser
  ash_admin "/"
end
```

It discovers the resources through the `:ash_domains` config, so no per-resource
admin configuration exists. Because it is behind `:dev_routes`, it is compiled
into dev and test only.

**AshJsonApi** — `FnbErpWeb.AshJsonApiRouter` declares all three domains, and
each resource carries a `json_api do routes do … end end` block. It is mounted
unguarded:

```elixir
scope "/api/json" do
  pipe_through [:api]

  forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
    path: "/api/json/open_api",
    default_model_expand_depth: 4

  forward "/", FnbErpWeb.AshJsonApiRouter
end
```

So the surface is:

| Path | What |
|---|---|
| `/admin` | AshAdmin UI (dev/test only, `:dev_routes`) |
| `/api/json` | JSON:API, all three domains |
| `/api/json/open_api` | OpenAPI document (`open_api: "/open_api"` on the router) |
| `/api/json/swaggerui` | SwaggerUI over that document |

`config/config.exs` registers `application/vnd.api+json` with `:mime` so the
JSON:API content type is accepted.

The only hand-written page is the generated Phoenix landing page at `/`.

## Alternatives Considered

### Bespoke LiveView CRUD screens

- **Pros:** full control of layout and wording; can express F&B-specific flows
  (a picking screen, a stock-count screen) that a generic admin cannot; the
  natural showcase for `ash_phoenix`'s `AshPhoenix.Form`.
- **Cons:** roughly seven index pages, seven forms, plus lifecycle buttons,
  filtering and error display — all of it code that has to be maintained and
  none of it domain logic. Adding an attribute would mean touching a template.
- **Rejected because:** the cost is concentrated entirely in plumbing, and
  AshAdmin covers "look at the data and run the actions" for free.
  `ash_phoenix` stays in the dependency list so this remains a cheap next step
  when a real user-facing flow is needed.

### AshGraphql instead of AshJsonApi

- **Pros:** one endpoint; typed schema; introspectable via GraphiQL; nested
  selection avoids the `include` dance.
- **Cons:** a `curl` example becomes a POSTed query document rather than a URL —
  worse for a copy-pasteable demo. Custom lifecycle actions become mutations
  with their own naming conventions, and pulling in Absinthe is a larger
  dependency for the same reach.
- **Rejected because:** JSON:API gives readable, per-resource URLs, filtering and
  `include` for free, plus an OpenAPI document and SwaggerUI, which is a better
  fit for a demo driven from a shell.

### Both AshJsonApi and AshGraphql

- **Pros:** demonstrates that resources really are transport-agnostic.
- **Cons:** two API surfaces to keep working and document, for one consumer.
- **Rejected because:** YAGNI. Adding it later is an extension and a router
  line, precisely because of [ADR-0001](0001-ash-framework-as-application-core.md).

## Consequences

- Adding an attribute to a resource updates the admin form and the API payload
  with no interface code changes.
- The JSON:API contract is self-documenting: the OpenAPI document and SwaggerUI
  are generated from the same resource definitions.
- **AshAdmin is unavailable outside dev/test.** Running with
  `MIX_ENV=prod` gives no admin UI at all — the `:dev_routes` guard is a compile
  time flag, not a runtime one. That is deliberate: the admin has no
  authentication in front of it (see
  [ADR-0006](0006-no-authentication-or-multitenancy.md)).
- **The JSON:API is *not* behind that guard and has no authentication.** In any
  environment where the app is reachable, so is full read/write access to the
  whole domain.
- UI wording and layout are whatever AshAdmin generates; resource and attribute
  descriptions in the DSL are the only lever over it.
- JSON:API's shape leaks into the demo: request bodies are
  `{"data": {"type": …, "attributes": {…}}}` and the content type is
  `application/vnd.api+json`.
