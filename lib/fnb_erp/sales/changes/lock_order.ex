defmodule FnbErp.Sales.Changes.LockOrder do
  @moduledoc """
  Serialises a status transition against concurrent callers.

  Transitions run with `require_atomic? false`, so `Validations.StatusIs` reads the
  status from the record the caller already loaded. Two concurrent `fulfil` calls
  can therefore both see `:confirmed` and both run the side effects — deducting
  stock twice for one order. This takes a `SELECT … FOR UPDATE` on the order row
  inside the action's transaction and re-checks the status against the locked row,
  so the loser of the race fails with the ordinary wrong-status error.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias FnbErp.Sales.Validations.StatusIs

  @impl true
  def init(opts), do: StatusIs.init(opts)

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      %{status: status} =
        FnbErp.Sales.Order
        |> Ash.Query.filter(id == ^changeset.data.id)
        |> Ash.Query.lock("FOR UPDATE")
        |> Ash.read_one!()

      case StatusIs.check(status, opts[:status]) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end
