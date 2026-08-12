defmodule FnbErp.Catalog.Customer do
  @moduledoc """
  A business that buys from us — a cafe, restaurant, retailer or distributor.

  Customers are never destroyed, only deactivated: orders reference them forever
  and a hard delete would orphan order history. See ASSUMPTIONS.md #15.
  """
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Catalog,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  json_api do
    type "customer"

    routes do
      base "/customers"
      get :read
      index :read
      post :create
      patch :update
    end
  end

  postgres do
    table "customers"
    repo FnbErp.Repo
  end

  actions do
    defaults [:read]

    default_accept [
      :name,
      :contact_name,
      :email,
      :phone,
      :address_line1,
      :address_line2,
      :city,
      :province,
      :postal_code,
      :country
    ]

    create :create do
      primary? true
    end

    update :update do
      primary? true
      require_atomic? false
    end

    update :deactivate do
      accept []
      # The resource-level email format validation cannot run atomically, and it
      # would re-run against the unchanged email on every atomic update.
      require_atomic? false
      change set_attribute(:active?, false)
    end

    update :activate do
      accept []
      # The resource-level email format validation cannot run atomically, and it
      # would re-run against the unchanged email on every atomic update.
      require_atomic? false
      change set_attribute(:active?, true)
    end

    read :active do
      filter expr(active? == true)
    end
  end

  validations do
    validate match(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/),
      where: [present(:email)],
      message: "must be a valid email address"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :contact_name, :string, public?: true
    attribute :email, :string, public?: true
    attribute :phone, :string, public?: true
    attribute :address_line1, :string, public?: true
    attribute :address_line2, :string, public?: true
    attribute :city, :string, public?: true
    attribute :province, :string, public?: true
    attribute :postal_code, :string, public?: true
    attribute :country, :string, public?: true, default: "ID"
    attribute :active?, :boolean, allow_nil?: false, public?: true, default: true

    timestamps()
  end

  relationships do
    has_many :orders, FnbErp.Sales.Order do
      public? true
      destination_attribute :customer_id
    end
  end

  identities do
    identity :unique_email, [:email], nils_distinct?: true
  end
end
