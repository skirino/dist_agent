use Croma

defmodule DistAgent.Config do
  @moduledoc """

  """

  defun tick_interval() :: pos_integer do
    1_000
  end

  defun quota_collection_interval() :: pos_integer do
    1_000
  end
end
