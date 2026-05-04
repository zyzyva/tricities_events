defmodule TricitiesEvents.Sources.ElizabethtonChamber do
  @behaviour TricitiesEvents.Source

  alias TricitiesEvents.Sources.ICalFeed

  @url "https://elizabethtonchamber.com/events-calendar/?ical=1"

  @impl true
  def name, do: "Elizabethton Chamber"

  @impl true
  def fetch, do: ICalFeed.fetch_url(@url, name())
end
