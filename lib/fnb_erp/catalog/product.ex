defmodule FnbErp.Catalog.Product do
  @moduledoc """
  Anything we buy or sell: raw materials (coffee beans, milk) and finished goods
  (a bottled cold brew). Only `:finished_good` products are sellable — see
  ASSUMPTIONS.md #12.
  """
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Catalog,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  @units_of_measure [:kg, :g, :l, :ml, :pcs, :box, :carton]
  @categories [:raw_material, :finished_good]

  def units_of_measure, do: @units_of_measure
  def categories, do: @categories

  json_api do
    type "product"

    routes do
      base "/products"
      get :read
      index :read
      post :create
      patch :update
    end
  end

  postgres do
    table "products"
    repo FnbErp.Repo
  end

  actions do
    defaults [:read]

    default_accept [:name, :sku, :description, :unit_price, :unit_of_measure, :category]

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_sku
    end

    update :update do
      primary? true
      require_atomic? false
    end

    update :deactivate do
      accept []
      change set_attribute(:active?, false)
    end

    read :sellable do
      filter expr(active? == true and category == :finished_good)
    end
  end

  validations do
    validate compare(:unit_price, greater_than_or_equal_to: 0),
      message: "must not be negative"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :sku, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :description, :string, public?: true

    attribute :unit_price, :decimal,
      allow_nil?: false,
      public?: true,
      constraints: [precision: 14, scale: 2]

    attribute :unit_of_measure, :atom,
      allow_nil?: false,
      public?: true,
      default: :pcs,
      constraints: [one_of: @units_of_measure]

    attribute :category, :atom,
      allow_nil?: false,
      public?: true,
      default: :finished_good,
      constraints: [one_of: @categories]

    attribute :active?, :boolean, allow_nil?: false, public?: true, default: true

    timestamps()
  end

  relationships do
    has_many :inventories, FnbErp.Warehouse.Inventory do
      public? true
      destination_attribute :product_id
    end
  end

  identities do
    identity :unique_sku, [:sku]
  end
end
