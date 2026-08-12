defmodule FnbErpWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: [FnbErp.Catalog, FnbErp.Warehouse, FnbErp.Sales],
    open_api: "/open_api"
end
