defmodule TricitiesEvents.Sources.IncredibleTowns do
  @behaviour TricitiesEvents.Source

  alias TricitiesEvents.Sources.ICalFeed

  @url "https://incredibletowns.com/?mec-ical-feed=1"

  @impl true
  def name, do: "Incredible Towns"

  @impl true
  def fetch, do: ICalFeed.fetch_url(@url, name())

  @impl true
  def multi_region?, do: true
end
