defmodule FnbErp.Warehouse.StockMovement do
  @moduledoc """
  Append-only ledger of stock changes. Rows are never updated or deleted — a
  mistake is corrected with a compensating movement, so the history stays audit-safe.
  """
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Warehouse,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  @reasons [:receipt, :sale, :adjustment, :return]
  def reasons, do: @reasons

  json_api do
    type "stock_movement"

    routes do
      base "/stock_movements"
      get :read
      index :read
    end
  end

  postgres do
    table "stock_movements"
    repo FnbErp.Repo

    references do
      reference :inventory, on_delete: :restrict
    end

    # Every read of the ledger is "the movements for this inventory row", and the
    # foreign key alone does not index it.
    custom_indexes do
      index [:inventory_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:inventory_id, :quantity, :reason, :reference]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :quantity, :decimal,
      allow_nil?: false,
      public?: true,
      description: "Signed: positive is stock in, negative is stock out.",
      constraints: [precision: 14, scale: 3]

    attribute :reason, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @reasons]

    attribute :reference, :string,
      public?: true,
      description: "Free-text origin, e.g. the order number that caused the movement."

    create_timestamp :occurred_at, public?: true
  end

  relationships do
    belongs_to :inventory, FnbErp.Warehouse.Inventory do
      allow_nil? false
      public? true
    end
  end
end
