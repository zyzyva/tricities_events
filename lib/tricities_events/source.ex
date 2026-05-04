defmodule TricitiesEvents.Source do
  @moduledoc """
  Behaviour every source module implements.
  Each source returns a list of `%Event{}` structs.
  """

  alias TricitiesEvents.Event

  @callback name() :: String.t()
  @callback fetch() :: {:ok, [Event.t()]} | {:error, term()}

  @doc """
  Whether the source publishes events outside the Tri-Cities region.
  Multi-region sources are filtered through `TricitiesEvents.Region`
  in the aggregator; single-region sources are trusted.
  """
  @callback multi_region?() :: boolean()

  @optional_callbacks multi_region?: 0
end
