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
