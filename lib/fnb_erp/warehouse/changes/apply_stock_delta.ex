defmodule FnbErp.Warehouse.Changes.ApplyStockDelta do
  @moduledoc """
  Adds the signed delta to the balance.

  Read-modify-write rather than an atomic `quantity_on_hand + delta` expression:
  Ash cannot atomically validate a decimal's precision constraint against an
  expression. Two concurrent movements on the same inventory row can therefore
  interleave — the `quantity_on_hand >= 0` check constraint stops that turning
  into negative stock, but the later write still wins.

  ponytail: last-write-wins on concurrent movements; wrap in a `SELECT ... FOR UPDATE`
  (or drop the precision constraint and go back to `atomic_update`) if concurrent
  fulfilment ever becomes real.
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
