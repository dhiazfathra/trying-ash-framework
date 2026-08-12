defmodule FnbErp.Sales.Changes.GenerateOrderNumber do
  @moduledoc """
  Stamps a human-readable `SO-YYYYMM-NNNN` number from a Postgres sequence, so two
  concurrent inserts can never collide on it. See ASSUMPTIONS.md #19.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      date = Ash.Changeset.get_attribute(changeset, :order_date) || Date.utc_today()
      %{rows: [[seq]]} = FnbErp.Repo.query!("SELECT nextval('order_number_seq')")

      number =
        "SO-#{date.year}#{String.pad_leading("#{date.month}", 2, "0")}-#{String.pad_leading("#{seq}", 4, "0")}"

      Ash.Changeset.force_change_attribute(changeset, :order_number, number)
    end)
  end
end

defmodule FnbErp.Sales.Changes.PriceLine do
  @moduledoc """
  Snapshots the product price onto the line when none was given, then recomputes
  the subtotal. Subtotal is stored rather than derived at read time so the order's
  total can be summed, filtered and sorted in SQL (ASSUMPTIONS.md #28).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      unit_price = Ash.Changeset.get_attribute(changeset, :unit_price) || product_price(changeset)
      quantity = Ash.Changeset.get_attribute(changeset, :quantity)

      changeset
      |> Ash.Changeset.force_change_attribute(:unit_price, unit_price)
      |> Ash.Changeset.force_change_attribute(
        :subtotal,
        Decimal.mult(quantity, unit_price) |> Decimal.round(2)
      )
    end)
  end

  defp product_price(changeset) do
    product_id = Ash.Changeset.get_attribute(changeset, :product_id)
    Ash.get!(FnbErp.Catalog.Product, product_id).unit_price
  end
end

defmodule FnbErp.Sales.Changes.DeductStock do
  @moduledoc """
  Issues stock for every line from the order's location when the order is fulfilled.

  Runs inside the update's transaction, so a line that cannot be picked rolls the
  whole fulfilment back — an order is never half-shipped.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, order ->
      order = Ash.load!(order, :lines)

      Enum.reduce_while(order.lines, {:ok, order}, fn line, acc ->
        case FnbErp.Warehouse.issue_stock(
               line.product_id,
               order.location_id,
               line.quantity,
               order.order_number
             ) do
          {:ok, _inventory} -> {:cont, acc}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end)
  end
end
