defmodule FnbErp.Repo do
  use AshPostgres.Repo,
    otp_app: :fnb_erp

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    ["ash-functions"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    # Pinned to 17, not to whatever `postgres -V` reports locally: on 18+ the
    # migration generator emits a native `uuidv7()` default that a 17 server
    # cannot run. 17 is the lowest version we claim to support.
    %Version{major: 17, minor: 0, patch: 0}
  end
end
