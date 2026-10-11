defmodule Nugitea.Accounts do
  @moduledoc """
  The app tier's own state dir (accounts.json, mirrors.json): everything but
  git data, which lives on the storage tier. NUGITEA_STATE_DIR.
  """

  def state_dir, do: Application.fetch_env!(:nugitea, :state_dir)
end
