defmodule FnbErp.Sales do
  @moduledoc "Sales orders and their lifecycle."
  use Ash.Domain, otp_app: :fnb_erp, extensions: [AshJsonApi.Domain]

  resources do
    resource FnbErp.Sales.Order do
      define :create_order, action: :create
      define :list_orders, action: :read
      define :get_order, action: :read, get_by: [:id]
      define :orders_by_status, action: :by_status, args: [:status]
      define :confirm_order, action: :confirm
      define :fulfil_order, action: :fulfil
      define :mark_order_paid, action: :mark_paid
      define :cancel_order, action: :cancel
    end

    resource FnbErp.Sales.OrderLine do
      define :add_order_line, action: :create
      define :update_order_line, action: :update
      define :remove_order_line, action: :destroy
      define :list_order_lines, action: :read
    end
  end
end
