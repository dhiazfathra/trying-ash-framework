defmodule FnbErp.Catalog.Changes.DowncaseEmail do
  @moduledoc """
  Normalises the email to lower case so the `unique_email` identity actually
  catches `HI@cafe.co.id` and `hi@cafe.co.id` as the same customer.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :email) do
      nil -> changeset
      email -> Ash.Changeset.force_change_attribute(changeset, :email, String.downcase(email))
    end
  end
end
