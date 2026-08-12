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
    check(changeset.data.status, opts[:status])
  end

  @doc """
  The guard itself, split out so `FnbErp.Sales.Changes.LockOrder` can re-run it
  against a freshly locked row and produce the identical error.
  """
  @spec check(atom(), [atom()]) :: :ok | {:error, Ash.Error.Changes.InvalidAttribute.t()}
  def check(current, allowed) do
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
