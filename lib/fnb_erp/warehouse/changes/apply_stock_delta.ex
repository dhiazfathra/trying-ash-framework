defmodule FnbErp.Warehouse.Changes.ApplyStockDelta do
  @moduledoc """
  Adds the signed delta to the balance.

  Read-modify-write rather than an atomic `quantity_on_hand + delta` expression:
  Ash cannot atomically validate a decimal's precision constraint against an
  expression. Concurrency safety therefore comes from the caller: every entry
  point holds a `SELECT … FOR UPDATE` lock on the inventory row for the whole
  read-modify-write plus ledger insert (see `FnbErp.Warehouse.apply_movement/5`),
  so movements against one row are serialised by Postgres.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    delta = Ash.Changeset.get_argument(changeset, :quantity)
    on_hand = changeset.data.quantity_on_hand || Decimal.new(0)

    Ash.Changeset.force_change_attribute(
      changeset,
      :quantity_on_hand,
      Decimal.add(on_hand, delta)
    )
  end
end
