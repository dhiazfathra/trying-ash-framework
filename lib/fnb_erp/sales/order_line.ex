defmodule FnbErp.Sales.OrderLine do
  @moduledoc """
  One product line on an order.

  `unit_price` is snapshotted from the product when the line is created, so
  repricing the catalogue never rewrites history (ASSUMPTIONS.md #5). Lines are
  only writable while the parent order is a draft (#7).
  """
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Sales,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  alias FnbErp.Sales.Changes
  alias FnbErp.Sales.Validations

  json_api do
    type "order_line"

    routes do
      base "/order_lines"
      get :read
      index :read
      post :create
      patch :update
      delete :destroy
    end
  end

  postgres do
    table "order_lines"
    repo FnbErp.Repo

    references do
      reference :order, on_delete: :delete
      reference :product, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:order_id, :product_id, :quantity, :unit_price]
      validate Validations.ParentOrderIsDraft
      validate Validations.ProductIsSellable
      change Changes.PriceLine
    end

    update :update do
      primary? true
      accept [:quantity, :unit_price]
      require_atomic? false
      validate Validations.ParentOrderIsDraft
      change Changes.PriceLine
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate Validations.ParentOrderIsDraft
    end
  end

  validations do
    validate compare(:quantity, greater_than: 0), message: "must be greater than zero"

    validate compare(:unit_price, greater_than_or_equal_to: 0),
      message: "must not be negative"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :quantity, :decimal,
      allow_nil?: false,
      public?: true,
      constraints: [precision: 14, scale: 3]

    attribute :unit_price, :decimal,
      public?: true,
      description: "Defaults to the product's price at the moment the line is created.",
      constraints: [precision: 14, scale: 2]

    attribute :subtotal, :decimal,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: Decimal.new(0),
      constraints: [precision: 16, scale: 2]

    timestamps()
  end

  relationships do
    belongs_to :order, FnbErp.Sales.Order do
      allow_nil? false
      public? true
    end

    belongs_to :product, FnbErp.Catalog.Product do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_product_per_order, [:order_id, :product_id]
  end
end
