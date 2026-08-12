defmodule FnbErp.Warehouse.Inventory do
  @moduledoc """
  The stock balance of one product at one location.

  `quantity_on_hand` is the materialised balance of the `FnbErp.Warehouse.StockMovement`
  ledger — every change to it goes through `record_movement/1`, which writes the
  matching ledger row in the same transaction. See ASSUMPTIONS.md #11.
  """
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Warehouse,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  json_api do
    type "inventory"

    routes do
      base "/inventories"
      get :read
      index :read
    end
  end

  postgres do
    table "inventories"
    repo FnbErp.Repo

    references do
      reference :product, on_delete: :restrict
      reference :location, on_delete: :restrict
    end

    # Belt to the validation's braces: no code path may drive stock negative.
    check_constraints do
      check_constraint :quantity_on_hand, "inventories_quantity_on_hand_non_negative",
        check: "quantity_on_hand >= 0",
        message: "would drive stock below zero"
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:product_id, :location_id, :quantity_on_hand]
      upsert? true
      upsert_identity :unique_product_location
      upsert_fields [:quantity_on_hand]
    end

    update :record_movement do
      description "Applies a signed quantity delta and writes the matching ledger row."
      require_atomic? false

      argument :quantity, :decimal, allow_nil?: false
      argument :reason, :atom, allow_nil?: false
      argument :reference, :string

      validate FnbErp.Warehouse.Validations.SufficientStock

      change FnbErp.Warehouse.Changes.ApplyStockDelta
      change FnbErp.Warehouse.Changes.RecordStockMovement
    end

    read :for_product do
      argument :product_id, :uuid, allow_nil?: false
      filter expr(product_id == ^arg(:product_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :quantity_on_hand, :decimal,
      allow_nil?: false,
      public?: true,
      default: Decimal.new(0),
      constraints: [precision: 14, scale: 3]

    timestamps()
  end

  relationships do
    belongs_to :product, FnbErp.Catalog.Product do
      allow_nil? false
      public? true
    end

    belongs_to :location, FnbErp.Warehouse.Location do
      allow_nil? false
      public? true
    end

    has_many :movements, FnbErp.Warehouse.StockMovement do
      public? true
      destination_attribute :inventory_id
    end
  end

  identities do
    identity :unique_product_location, [:product_id, :location_id]
  end
end
