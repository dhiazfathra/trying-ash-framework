defmodule FnbErp.Warehouse.Location do
  @moduledoc "A physical stockholding place: a warehouse, cold room or outlet store."
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Warehouse,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  json_api do
    type "location"

    routes do
      base "/locations"
      get :read
      index :read
      post :create
      patch :update
    end
  end

  postgres do
    table "locations"
    repo FnbErp.Repo
  end

  actions do
    defaults [:read]
    default_accept [:name, :code, :address]

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_code
    end

    update :update do
      primary? true
      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :code, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :address, :string, public?: true
    attribute :active?, :boolean, allow_nil?: false, public?: true, default: true

    timestamps()
  end

  relationships do
    has_many :inventories, FnbErp.Warehouse.Inventory do
      public? true
      destination_attribute :location_id
    end
  end

  identities do
    identity :unique_code, [:code]
  end
end
