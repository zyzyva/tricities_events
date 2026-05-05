defmodule TricitiesEvents.Sources.JohnsonCityChamber do
  @moduledoc """
  Scrapes the Johnson City, TN Chamber of Commerce events calendar.

  The chamber runs on CC-Assist.NET (chamberdata.com), an ASP.NET WebForms
  app that exposes no iCal/RSS feed and gates month navigation behind
  postbacks with VIEWSTATE. We scrape the default listing page (which
  shows the current month plus prev/next-month spillover days), extract
  every `evtid` we see, then fetch each event's detail page in parallel.

  Detail pages have clean, predictable structure:

      <div class="ccaEvtListingEvtName">Title</div>
      <div class="ccaEvtListingWhen">
        <div class="ccaEvtListingDetailText">Thursday, April 30, 2026 5:30 PM thru 07:30 PM</div>
      </div>
      <div class="ccaEvtListingWhere">
        <div class="ccaEvtListingDetailText">Venue<br/>Street<br/>City, ST ZIP</div>
      </div>
      <div class="ccaEvtListingDesc">…</div>
  """

  @behaviour TricitiesEvents.Source

  require Logger

  alias TricitiesEvents.Event

  @base_url "https://cca.johnsoncitytnchamber.com"
  @listing_url "#{@base_url}/evtlistingmainsearch.aspx"
  @user_agent "TricitiesEvents/0.1 (calendar aggregator)"

  @months %{
    "January" => 1, "February" => 2, "March" => 3, "April" => 4,
    "May" => 5, "June" => 6, "July" => 7, "August" => 8,
    "September" => 9, "October" => 10, "November" => 11, "December" => 12
  }

  @impl true
  def name, do: "Johnson City Chamber"

  @impl true
  def multi_region?, do: false

  @impl true
  def fetch do
    with {:ok, %{status: 200, body: html}} <- request(@listing_url) do
      evtids = parse_listing_evtids(html)

      events =
        evtids
        |> Task.async_stream(&fetch_event/1, max_concurrency: 4, timeout: 30_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, {:ok, event}} -> [event]
          {:ok, {:error, reason}} -> Logger.warning("JCC detail parse failed: #{inspect(reason)}"); []
          {:exit, reason} -> Logger.warning("JCC detail fetch crashed: #{inspect(reason)}"); []
        end)

      {:ok, events}
    else
      {:ok, %{status: status}} -> {:error, {:bad_status, status}}
      err -> {:error, err}
    end
  end

  @doc false
  def parse_listing_evtids(html) do
    Regex.scan(~r/ccaId_divEvtInfo\d{4}_(\d+)/, html, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  @doc false
  def parse_detail(html, evtid) do
    with {:ok, doc} <- Floki.parse_document(html),
         summary when is_binary(summary) <- text_of(doc, ".ccaEvtListingEvtName"),
         when_text when is_binary(when_text) <- text_of(doc, ".ccaEvtListingWhen .ccaEvtListingDetailText"),
         {:ok, starts_at, ends_at} <- parse_when(when_text) do
      {:ok,
       %Event{
         uid: build_uid(evtid),
         source: name(),
         summary: summary,
         description: text_of(doc, ".ccaEvtListingDesc"),
         location: parse_location(doc),
         url: "#{@base_url}/EvtListing.aspx?dbid2=TNJC&evtid=#{evtid}&class=E",
         starts_at: starts_at,
         ends_at: ends_at
       }}
    else
      err -> {:error, {:bad_detail, err}}
    end
  end

  defp fetch_event(evtid) do
    url = "#{@base_url}/EvtListing.aspx?dbid2=TNJC&evtid=#{evtid}&class=E"

    with {:ok, %{status: 200, body: html}} <- request(url) do
      parse_detail(html, evtid)
    else
      err -> {:error, err}
    end
  end

  defp request(url) do
    Req.get(url, headers: [{"user-agent", @user_agent}])
  end

  # "Thursday, April 30, 2026 5:30 PM thru 07:30 PM"  → {:ok, start_utc, end_utc}
  # "Wednesday, May 13, 2026 7:00 AM"                  → {:ok, start_utc, nil}
  defp parse_when(text) do
    text = String.trim(text)

    case Regex.run(
           ~r/^[A-Za-z]+,\s+([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})\s+(\d{1,2}:\d{2}\s+[AP]M)(?:\s+thru\s+(.+))?$/i,
           text
         ) do
      [_, month_name, day, year, start_time, end_text] ->
        with {:ok, start_dt} <- build_local_dt(year, month_name, day, start_time),
             {:ok, end_dt} <- parse_end(end_text, start_dt) do
          {:ok, to_utc(start_dt), to_utc(end_dt)}
        end

      [_, month_name, day, year, start_time] ->
        with {:ok, start_dt} <- build_local_dt(year, month_name, day, start_time) do
          {:ok, to_utc(start_dt), nil}
        end

      _ ->
        {:error, {:unparseable_when, text}}
    end
  end

  # End text variants:
  #   "07:30 PM"                            → same date, just a time
  #   "May 1, 2026 7:00 AM"                 → different date entirely
  #   "Friday, May 1, 2026 7:00 AM"
  defp parse_end(end_text, start_dt) do
    end_text = String.trim(end_text)

    case Regex.run(
           ~r/^(?:[A-Za-z]+,\s+)?([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})\s+(\d{1,2}:\d{2}\s+[AP]M)$/i,
           end_text
         ) do
      [_, month_name, day, year, time] ->
        build_local_dt(year, month_name, day, time)

      _ ->
        case Regex.run(~r/^(\d{1,2}:\d{2}\s+[AP]M)$/i, end_text) do
          [_, time] -> build_local_dt(start_dt.year, start_dt.month, start_dt.day, time)
          _ -> {:error, {:unparseable_end, end_text}}
        end
    end
  end

  defp build_local_dt(year, month_name, day, time) when is_binary(year) do
    case Map.get(@months, month_name) do
      nil -> {:error, {:bad_month, month_name}}
      m -> build_local_dt(String.to_integer(year), m, String.to_integer(day), time)
    end
  end

  defp build_local_dt(year, month, day, time) when is_integer(year) do
    with {:ok, time_struct} <- parse_clock(time),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, dt} <- DateTime.new(date, time_struct, "America/New_York") do
      {:ok, dt}
    end
  end

  defp parse_clock(time) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})\s+([AP])M$/i, String.trim(time)) do
      [_, h, m, ap] ->
        hour = String.to_integer(h)
        minute = String.to_integer(m)
        adjusted = adjust_hour(hour, String.upcase(ap))
        Time.new(adjusted, minute, 0)

      _ ->
        {:error, {:bad_time, time}}
    end
  end

  defp adjust_hour(12, "A"), do: 0
  defp adjust_hour(12, "P"), do: 12
  defp adjust_hour(h, "A"), do: h
  defp adjust_hour(h, "P"), do: h + 12

  defp to_utc(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp text_of(doc, selector) do
    case doc |> Floki.find(selector) |> List.first() do
      nil ->
        nil

      element ->
        # Strip the inner DetailLabel span (e.g. "When:") since `.ccaEvtListingWhen`
        # contains both the label and the text — we only want the text.
        element
        |> Floki.children()
        |> Enum.reject(&label_node?/1)
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end
    end
  end

  defp label_node?({_, attrs, _}) do
    attrs
    |> Enum.any?(fn {k, v} -> k == "class" and String.contains?(v, "ccaEvtListingDetailLabel") end)
  end

  defp label_node?(_), do: false

  defp parse_location(doc) do
    case Floki.find(doc, ".ccaEvtListingWhere .ccaEvtListingDetailText") |> List.first() do
      nil ->
        nil

      element ->
        element
        |> Floki.raw_html()
        |> String.replace(~r{<br\s*/?>}i, ", ")
        |> Floki.parse_fragment!()
        |> Floki.text()
        |> String.replace(~r/\s+/, " ")
        |> String.replace(~r/\s*,(\s*,)+/, ",")
        |> String.replace(~r/\s+,/, ",")
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end
    end
  end

  defp build_uid(evtid) do
    raw = "jcc|#{evtid}"
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    "#{hash}@tricities-events"
  end
end
