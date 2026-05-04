defmodule TricitiesEvents.Sources.ICalFeed do
  @moduledoc """
  Generic helper for sources that expose a public iCal feed.
  Specific source modules supply name + URL and call `fetch_url/2`.
  """

  alias TricitiesEvents.ICal

  @user_agent "TricitiesEvents/0.1 (calendar aggregator)"

  def fetch_url(url, source_name) do
    case Req.get(url,
           headers: [{"user-agent", @user_agent}],
           decode_body: false,
           receive_timeout: 60_000,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        if looks_like_ical?(body) do
          {:ok, ICal.parse(body, source_name)}
        else
          {:error, {:not_ical, String.slice(body, 0, 200)}}
        end

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp looks_like_ical?(body) do
    String.contains?(body, "BEGIN:VCALENDAR")
  end
end
