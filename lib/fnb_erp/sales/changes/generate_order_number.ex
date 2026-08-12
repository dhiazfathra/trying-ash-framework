defmodule FnbErp.Sales.Changes.GenerateOrderNumber do
  @moduledoc """
  Stamps a human-readable `SO-YYYYMM-NNNN` number from a Postgres sequence, so two
  concurrent inserts can never collide on it. See ASSUMPTIONS.md #19.

  The sequence is global and never resets, so `NNNN` is *at least* four digits —
  order 10 000 is `SO-202603-10000`. Zero-padding is cosmetic; uniqueness comes
  from the sequence, and per-month resetting would need a second counter to stay
  race-free.
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
