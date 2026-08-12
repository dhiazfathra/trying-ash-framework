defmodule FnbErp.Catalog do
  @moduledoc "What we sell and who we sell it to."
  use Ash.Domain, otp_app: :fnb_erp, extensions: [AshJsonApi.Domain]

  resources do
    resource FnbErp.Catalog.Product do
      define :create_product, action: :create
      define :list_products, action: :read
      define :list_sellable_products, action: :sellable
      define :get_product, action: :read, get_by: [:id]
      define :get_product_by_sku, action: :read, get_by: [:sku]
      define :deactivate_product, action: :deactivate
    end

    resource FnbErp.Catalog.Customer do
      define :create_customer, action: :create
      define :list_customers, action: :read
      define :list_active_customers, action: :active
      define :get_customer, action: :read, get_by: [:id]
      define :deactivate_customer, action: :deactivate
    end
  end
end
