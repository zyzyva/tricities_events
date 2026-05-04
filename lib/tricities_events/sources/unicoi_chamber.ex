defmodule TricitiesEvents.Sources.UnicoiChamber do
  @behaviour TricitiesEvents.Source

  alias TricitiesEvents.Sources.ICalFeed

  @url "https://unicoicounty.org/events/?ical=1"

  @impl true
  def name, do: "Unicoi County Chamber"

  @impl true
  def fetch do
    case ICalFeed.fetch_url(@url, name()) do
      {:ok, events} -> {:ok, events}
      # The advertised iCal URL has been observed returning HTML during
      # plugin outages; surface as empty rather than failing the run.
      {:error, {:not_ical, _}} -> {:ok, []}
      err -> err
    end
  end
end
