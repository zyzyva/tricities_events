defmodule TricitiesEvents.Sources.Custom do
  @moduledoc """
  Reads hand-curated events from `priv/custom_events.json` and emits them
  alongside scraped events. Supports one-off entries and recurring entries
  (weekly or monthly) that are expanded into concrete instances within a
  rolling horizon window.

  Use this for events that the upstream organizations don't publish on
  their own calendars — recurring breakfasts, monthly lunches, etc.

  See `priv/custom_events.json` for the file format.
  """

  @behaviour TricitiesEvents.Source

  require Logger

  alias TricitiesEvents.Event

  @default_horizon_days 365
  @default_timezone "America/New_York"
  @weekday_codes %{
    "MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7
  }

  @impl true
  def name, do: "Custom"

  @impl true
  def multi_region?, do: false

  @impl true
  def fetch do
    path = Path.join([Application.app_dir(:tricities_events, "priv"), "custom_events.json"])
    fetch_from(path)
  end

  @doc false
  def fetch_from(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"events" => specs}} when is_list(specs) <- JSON.decode(body) do
      events = Enum.flat_map(specs, &expand_spec/1)
      {:ok, events}
    else
      {:error, :enoent} ->
        Logger.info("No custom_events.json found at #{path} — skipping custom events")
        {:ok, []}

      {:ok, _other} ->
        Logger.warning("custom_events.json has unexpected shape — expected top-level {events: [...]}")
        {:ok, []}

      {:error, reason} ->
        Logger.warning("custom_events.json parse failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp expand_spec(%{"summary" => summary, "starts_at" => starts_at_str} = spec) do
    tz = Map.get(spec, "timezone", @default_timezone)

    case parse_local(starts_at_str, tz) do
      {:ok, base_start_utc} ->
        spec
        |> recurrence_dates(base_start_utc)
        |> Enum.map(&build_event(spec, summary, &1))

      :error ->
        Logger.warning("custom_events.json: bad starts_at #{inspect(starts_at_str)} for #{inspect(summary)}")
        []
    end
  end

  defp expand_spec(spec) do
    Logger.warning("custom_events.json: skipping entry missing summary or starts_at: #{inspect(spec)}")
    []
  end

  defp build_event(spec, summary, %DateTime{} = starts_at) do
    duration = Map.get(spec, "duration_minutes")
    ends_at = duration && DateTime.add(starts_at, duration * 60, :second)

    %Event{
      uid: build_uid(spec, summary, starts_at),
      source: name(),
      summary: summary,
      description: spec["description"],
      location: spec["location"],
      url: spec["url"],
      starts_at: starts_at,
      ends_at: ends_at
    }
  end

  defp build_uid(spec, summary, %DateTime{} = dt) do
    raw = "custom|#{summary}|#{spec["location"]}|#{DateTime.to_iso8601(dt)}"
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    "#{hash}@tricities-events"
  end

  # --- recurrence expansion ---

  defp recurrence_dates(spec, base_start_utc) do
    case Map.get(spec, "recurrence") do
      nil -> [base_start_utc]
      rec when is_map(rec) -> expand_recurrence(rec, base_start_utc, spec)
    end
  end

  defp expand_recurrence(rec, base_start_utc, spec) do
    count = rec["count"]
    end_dt = recurrence_end(rec, base_start_utc, spec, count)

    candidates =
      case Map.get(rec, "freq") do
        "weekly" -> weekly_candidates(rec, base_start_utc, end_dt)
        "monthly" -> monthly_candidates(rec, base_start_utc, end_dt)
        other ->
          Logger.warning("custom_events.json: unknown recurrence freq #{inspect(other)} — treating as one-off")
          [base_start_utc]
      end

    candidates
    |> Enum.filter(&(DateTime.compare(&1, end_dt) != :gt))
    |> maybe_take(count)
  end

  # Window in which to generate candidate dates. Anchored on the later of
  # `now` and `base_start` so series defined for the future still expand.
  # `until` clips it; `count`-bounded series widen to ensure we find enough.
  defp recurrence_end(rec, base_start_utc, spec, count) do
    anchor =
      if DateTime.compare(base_start_utc, DateTime.utc_now()) == :gt,
        do: base_start_utc,
        else: DateTime.utc_now()

    horizon_days =
      cond do
        is_integer(count) and count > 0 -> 365 * 10
        true -> Map.get(spec, "horizon_days", @default_horizon_days)
      end

    horizon = DateTime.add(anchor, horizon_days * 86_400, :second)
    parse_until(rec["until"], horizon)
  end

  defp parse_until(nil, default), do: default

  defp parse_until(date_str, default) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date
        |> DateTime.new!(~T[23:59:59], "America/New_York")
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        default
    end
  end

  defp maybe_take(events, nil), do: events
  defp maybe_take(events, n) when is_integer(n) and n > 0, do: Enum.take(events, n)

  # Weekly: produce one instance per matching weekday between base_start and end_dt.
  # `byday` is a list of weekday codes ("MO", "TU", ...). Falls back to the
  # base_start's weekday if not provided.
  defp weekly_candidates(rec, base_start, end_dt) do
    interval = Map.get(rec, "interval", 1)
    bydays = bydays_to_iso(rec["byday"], default_from(base_start))

    base_date = DateTime.to_date(base_start)
    base_week_monday = monday_of(base_date)
    end_date = DateTime.to_date(end_dt)

    Stream.iterate(base_week_monday, &Date.add(&1, interval * 7))
    |> Stream.take_while(&(Date.compare(&1, end_date) != :gt))
    |> Enum.flat_map(fn week_monday ->
      Enum.map(bydays, fn dow -> Date.add(week_monday, dow - 1) end)
    end)
    |> Enum.filter(&(Date.compare(&1, base_date) != :lt))
    |> Enum.map(&apply_time(&1, base_start))
    |> Enum.uniq()
    |> Enum.sort({:asc, DateTime})
  end

  # Monthly: either by `bymonthday` (15th of each month) or by `byday` like
  # "1TU" (first Tuesday). Falls back to the base_start's day-of-month.
  defp monthly_candidates(rec, base_start, end_dt) do
    interval = Map.get(rec, "interval", 1)
    base_date = DateTime.to_date(base_start)
    end_date = DateTime.to_date(end_dt)

    months =
      Stream.iterate({base_date.year, base_date.month}, fn {y, m} ->
        next = m + interval
        {y + div(next - 1, 12), rem(next - 1, 12) + 1}
      end)
      |> Stream.take_while(fn {y, m} ->
        last = Date.new!(y, m, 1)
        Date.compare(last, end_date) != :gt
      end)

    months
    |> Enum.flat_map(fn {y, m} -> month_dates(rec, y, m, base_date) end)
    |> Enum.filter(&(Date.compare(&1, base_date) != :lt))
    |> Enum.map(&apply_time(&1, base_start))
    |> Enum.uniq()
    |> Enum.sort({:asc, DateTime})
  end

  defp month_dates(%{"bymonthday" => day}, y, m, _base) when is_integer(day) do
    case Date.new(y, m, day) do
      {:ok, d} -> [d]
      _ -> []
    end
  end

  defp month_dates(%{"byday" => byday}, y, m, _base) when is_binary(byday) do
    case parse_nth_weekday(byday) do
      {:ok, n, dow} -> [nth_weekday_of_month(y, m, n, dow)] |> Enum.reject(&is_nil/1)
      :error -> []
    end
  end

  defp month_dates(_rec, y, m, base) do
    case Date.new(y, m, base.day) do
      {:ok, d} -> [d]
      _ -> []
    end
  end

  # Parses things like "1TU" → {:ok, 1, 2}, "-1FR" → {:ok, -1, 5}
  defp parse_nth_weekday(str) do
    with {n, rest} when rest != "" <- Integer.parse(str),
         dow when is_integer(dow) <- Map.get(@weekday_codes, rest) do
      {:ok, n, dow}
    else
      _ -> :error
    end
  end

  defp nth_weekday_of_month(year, month, n, dow) when n > 0 do
    first = Date.new!(year, month, 1)
    offset = rem(dow - Date.day_of_week(first) + 7, 7)
    candidate = Date.add(first, offset + (n - 1) * 7)
    if candidate.month == month, do: candidate, else: nil
  end

  defp nth_weekday_of_month(year, month, n, dow) when n < 0 do
    last = last_day_of_month(year, month)
    last_date = Date.new!(year, month, last)
    offset = rem(Date.day_of_week(last_date) - dow + 7, 7)
    candidate = Date.add(last_date, -(offset + (-n - 1) * 7))
    if candidate.month == month, do: candidate, else: nil
  end

  defp last_day_of_month(year, month) do
    Date.new!(year, month, 1) |> Date.end_of_month() |> Map.fetch!(:day)
  end

  defp bydays_to_iso(nil, default), do: [default]
  defp bydays_to_iso(code, default) when is_binary(code), do: bydays_to_iso([code], default)

  defp bydays_to_iso(codes, _default) when is_list(codes) do
    codes
    |> Enum.map(&Map.get(@weekday_codes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp default_from(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.day_of_week()

  defp monday_of(%Date{} = date) do
    Date.add(date, -(Date.day_of_week(date) - 1))
  end

  # Combine a date with the time-of-day of the base_start, in the same timezone,
  # then shift to UTC.
  defp apply_time(%Date{} = date, %DateTime{} = base_start) do
    local = DateTime.shift_zone!(base_start, base_start.time_zone)
    {:ok, dt} = DateTime.new(date, DateTime.to_time(local), local.time_zone)
    DateTime.shift_zone!(dt, "Etc/UTC")
  end

  # Parse "YYYY-MM-DDTHH:MM" (with optional :SS) as local time in tz, return UTC.
  defp parse_local(str, tz) when is_binary(str) do
    normalized =
      case String.length(str) do
        16 -> str <> ":00"
        _ -> str
      end

    with {:ok, naive} <- NaiveDateTime.from_iso8601(normalized),
         {:ok, local} <- DateTime.from_naive(naive, tz) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp parse_local(_, _), do: :error
end
