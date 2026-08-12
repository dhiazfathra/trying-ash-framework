defmodule FnbErp.Sales.Validations.StatusIs do
  @moduledoc "Guards a workflow transition by asserting the order's current status."
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :status) do
      {:ok, status} -> {:ok, Keyword.put(opts, :status, List.wrap(status))}
      :error -> {:error, "`status` is required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    allowed = opts[:status]
    current = changeset.data.status

    if current in allowed do
      :ok
    else
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :status,
         message: "cannot be done on a %{current} order, only on: %{allowed}",
         vars: [current: current, allowed: Enum.join(allowed, ", ")]
       )}
    end
  end
end

defmodule FnbErp.Sales.Validations.HasLines do
  @moduledoc "Rejects confirming an empty order."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    order = Ash.load!(changeset.data, :lines)

    if order.lines == [] do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :lines,
         message: "an order needs at least one line before it can be confirmed"
       )}
    else
      :ok
    end
  end
end

defmodule FnbErp.Sales.Validations.StockAvailable do
  @moduledoc """
  Checks every line can be picked from the order's location before we let the
  order be confirmed. Stock is not reserved, so this is an early warning — the
  authoritative check happens again when stock is deducted on fulfil.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    order = Ash.load!(changeset.data, lines: [:product])

    order.lines
    |> Enum.reduce([], fn line, errors ->
      on_hand = FnbErp.Warehouse.available_quantity(line.product_id, order.location_id)

      if Decimal.lt?(on_hand, line.quantity) do
        ["#{line.product.sku}: #{on_hand} available, #{line.quantity} ordered" | errors]
      else
        errors
      end
    end)
    |> case do
      [] ->
        :ok

      shortages ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :lines,
           message: "insufficient stock — %{shortages}",
           vars: [shortages: shortages |> Enum.reverse() |> Enum.join("; ")]
         )}
    end
  end
end

defmodule FnbErp.Sales.Validations.ParentOrderIsDraft do
  @moduledoc "Order lines are only writable while the order is still a draft."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    order_id = Ash.Changeset.get_attribute(changeset, :order_id)

    case Ash.get(FnbErp.Sales.Order, order_id) do
      {:ok, %{status: :draft}} ->
        :ok

      {:ok, order} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :order_id,
           message: "lines cannot be changed on a %{status} order",
           vars: [status: order.status]
         )}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule FnbErp.Sales.Validations.ProductIsSellable do
  @moduledoc "Only active finished goods can be sold. See ASSUMPTIONS.md #12."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    product_id = Ash.Changeset.get_attribute(changeset, :product_id)

    case Ash.get(FnbErp.Catalog.Product, product_id) do
      {:ok, %{active?: true, category: :finished_good}} ->
        :ok

      {:ok, product} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :product_id,
           message: "%{sku} is not sellable (category %{category}, active %{active})",
           vars: [sku: product.sku, category: product.category, active: product.active?]
         )}

      {:error, error} ->
        {:error, error}
    end
  end
end
