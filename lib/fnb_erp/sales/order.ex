defmodule FnbErp.Sales.Order do
  @moduledoc """
  A sales order header.

  Lifecycle: `draft → confirmed → fulfilled → paid`, with `cancelled` reachable from
  `draft` or `confirmed` only. Stock is checked on confirm and deducted on fulfil —
  there is no separate reservation step. See ASSUMPTIONS.md #6, #8, #9.
  """
  use Ash.Resource,
    otp_app: :fnb_erp,
    domain: FnbErp.Sales,
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  alias FnbErp.Sales.Changes
  alias FnbErp.Sales.Validations

  @statuses [:draft, :confirmed, :fulfilled, :paid, :cancelled]
  def statuses, do: @statuses

  @default_tax_rate Decimal.new("0.11")
  def default_tax_rate, do: @default_tax_rate

  json_api do
    type "order"

    routes do
      base "/orders"
      get :read
      index :read
      post :create
      patch :update
      patch :confirm, route: "/:id/confirm"
      patch :fulfil, route: "/:id/fulfil"
      patch :mark_paid, route: "/:id/mark_paid"
      patch :cancel, route: "/:id/cancel"
    end
  end

  postgres do
    table "orders"
    repo FnbErp.Repo

    references do
      reference :customer, on_delete: :restrict
      reference :location, on_delete: :restrict
    end

    custom_statements do
      statement :order_number_sequence do
        up "CREATE SEQUENCE IF NOT EXISTS order_number_seq"
        down "DROP SEQUENCE IF EXISTS order_number_seq"
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:customer_id, :location_id, :order_date, :tax_rate, :notes]
      change Changes.GenerateOrderNumber
    end

    update :update do
      primary? true
      accept [:order_date, :tax_rate, :notes]
      require_atomic? false
      validate {Validations.StatusIs, status: :draft}
    end

    update :confirm do
      description "Locks the lines and checks stock is available to fulfil the order."
      accept []
      require_atomic? false
      validate {Validations.StatusIs, status: :draft}
      validate Validations.HasLines
      validate Validations.StockAvailable
      change set_attribute(:status, :confirmed)
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :fulfil do
      description "Ships the order and deducts stock from the order's location."
      accept []
      require_atomic? false
      validate {Validations.StatusIs, status: :confirmed}
      change set_attribute(:status, :fulfilled)
      change set_attribute(:fulfilled_at, &DateTime.utc_now/0)
      change Changes.DeductStock
    end

    update :mark_paid do
      accept []
      require_atomic? false
      validate {Validations.StatusIs, status: :fulfilled}
      change set_attribute(:status, :paid)
      change set_attribute(:paid_at, &DateTime.utc_now/0)
    end

    update :cancel do
      accept [:cancellation_reason]
      require_atomic? false
      validate {Validations.StatusIs, status: [:draft, :confirmed]}
      change set_attribute(:status, :cancelled)
      change set_attribute(:cancelled_at, &DateTime.utc_now/0)
    end

    read :by_status do
      argument :status, :atom, allow_nil?: false
      filter expr(status == ^arg(:status))
    end
  end

  validations do
    validate compare(:tax_rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 1),
      message: "must be a rate between 0 and 1"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :order_number, :string, allow_nil?: false, public?: true, writable?: false

    attribute :order_date, :date,
      allow_nil?: false,
      public?: true,
      default: &Date.utc_today/0

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      default: :draft,
      writable?: false,
      constraints: [one_of: @statuses]

    attribute :tax_rate, :decimal,
      allow_nil?: false,
      public?: true,
      default: @default_tax_rate,
      constraints: [precision: 5, scale: 4]

    attribute :notes, :string, public?: true
    attribute :cancellation_reason, :string, public?: true

    attribute :confirmed_at, :utc_datetime_usec, public?: true, writable?: false
    attribute :fulfilled_at, :utc_datetime_usec, public?: true, writable?: false
    attribute :paid_at, :utc_datetime_usec, public?: true, writable?: false
    attribute :cancelled_at, :utc_datetime_usec, public?: true, writable?: false

    timestamps()
  end

  relationships do
    belongs_to :customer, FnbErp.Catalog.Customer do
      allow_nil? false
      public? true
    end

    belongs_to :location, FnbErp.Warehouse.Location do
      allow_nil? false
      public? true
      description "The warehouse the whole order is picked from. See ASSUMPTIONS.md #10."
    end

    has_many :lines, FnbErp.Sales.OrderLine do
      public? true
      destination_attribute :order_id
    end
  end

  calculations do
    calculate :tax_amount, :decimal, expr(subtotal * tax_rate), public?: true
    calculate :total, :decimal, expr(subtotal + subtotal * tax_rate), public?: true
  end

  aggregates do
    sum :subtotal, :lines, :subtotal, default: Decimal.new(0)
    count :line_count, :lines
  end

  identities do
    identity :unique_order_number, [:order_number]
  end
end
