defmodule TricitiesEvents.ICal do
  @moduledoc """
  Minimal iCalendar parser and generator.

  Parser: pulls VEVENT blocks out of a VCALENDAR document, extracts
  enough structured data to build %Event{} structs while keeping the
  raw VEVENT block for passthrough.

  Generator: wraps a list of %Event{} structs in a VCALENDAR document,
  preserving raw VEVENT blocks where present and generating new ones
  from structured fields otherwise.
  """

  alias TricitiesEvents.Event

  @prodid "-//TricitiesEvents//Aggregator//EN"

  # Short, calendar-list-friendly aliases prepended to event summaries so
  # subscribers can tell at a glance which org is hosting. Sources not in
  # this map (notably "Custom") are not tagged — Custom event summaries
  # are user-curated and already self-describing.
  @source_tags %{
    "Elizabethton Chamber" => "Eliz Chamber",
    "Incredible Towns" => "Incredible Towns",
    "Unicoi County Chamber" => "Unicoi Chamber",
    "FoundersForge" => "Founders Forge",
    "Johnson City Chamber" => "JC Chamber"
  }

  @doc "Parse a raw iCal document into a list of %Event{} structs."
  def parse(ics, source_name) do
    ics
    |> unfold_lines()
    |> extract_vevent_blocks()
    |> Enum.map(&block_to_event(&1, source_name))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Generate a VCALENDAR document from a list of %Event{} structs."
  def generate(events) do
    body =
      events
      |> Enum.map(&event_to_vevent/1)
      |> Enum.join("\r\n")

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:#{@prodid}
    CALSCALE:GREGORIAN
    METHOD:PUBLISH
    X-WR-CALNAME:Tri-Cities Events
    X-WR-CALDESC:Aggregated networking and community events across the Tri-Cities, TN/VA region
    X-WR-TIMEZONE:America/New_York
    #{body}
    END:VCALENDAR
    """
    |> String.replace("\n", "\r\n")
    |> String.trim_trailing("\r\n")
    |> Kernel.<>("\r\n")
  end

  # --- parsing ---

  # Lines split across multiple lines via leading whitespace are joined
  # back into one logical line per RFC 5545.
  defp unfold_lines(ics) do
    ics
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.reduce([], fn
      <<" ", rest::binary>>, [last | acc] -> [last <> rest | acc]
      <<"\t", rest::binary>>, [last | acc] -> [last <> rest | acc]
      line, acc -> [line | acc]
    end)
    |> Enum.reverse()
  end

  defp extract_vevent_blocks(lines) do
    {blocks, _current} =
      Enum.reduce(lines, {[], nil}, fn
        "BEGIN:VEVENT", {acc, nil} -> {acc, ["BEGIN:VEVENT"]}
        "END:VEVENT", {acc, current} when is_list(current) ->
          {[Enum.reverse(["END:VEVENT" | current]) | acc], nil}
        line, {acc, current} when is_list(current) -> {acc, [line | current]}
        _line, {acc, nil} -> {acc, nil}
      end)

    blocks |> Enum.reverse()
  end

  defp block_to_event(lines, source_name) do
    raw_block = Enum.join(lines, "\r\n")
    fields = Map.new(lines, &split_property/1)

    with {:ok, starts_at} <- parse_dt(fields["DTSTART"]),
         summary when is_binary(summary) <- fields["SUMMARY"] do
      %Event{
        uid: fields["UID"] || generate_uid(summary, starts_at, source_name),
        source: source_name,
        summary: unescape(summary),
        description: unescape(fields["DESCRIPTION"]),
        location: unescape(fields["LOCATION"]),
        url: fields["URL"],
        starts_at: starts_at,
        ends_at: fields["DTEND"] |> parse_dt() |> case do
          {:ok, dt} -> dt
          _ -> nil
        end,
        vevent_block: raw_block
      }
    else
      _ -> nil
    end
  end

  defp split_property(line) do
    case String.split(line, ":", parts: 2) do
      [key_with_params, value] ->
        key = key_with_params |> String.split(";") |> List.first()
        {key, value}

      _ ->
        {nil, nil}
    end
  end

  # Parse an iCal DTSTART/DTEND value into a UTC DateTime.
  # Handles UTC suffix Z, floating local times, and TZID-prefixed values.
  defp parse_dt(nil), do: :error
  defp parse_dt(<<year::binary-size(4), month::binary-size(2), day::binary-size(2),
                  "T", hour::binary-size(2), min::binary-size(2), sec::binary-size(2),
                  "Z">>) do
    DateTime.new(
      Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
      Time.new!(String.to_integer(hour), String.to_integer(min), String.to_integer(sec)),
      "Etc/UTC"
    )
  end

  defp parse_dt(<<year::binary-size(4), month::binary-size(2), day::binary-size(2),
                  "T", hour::binary-size(2), min::binary-size(2), sec::binary-size(2)>>) do
    # Floating/local time — assume America/New_York (all our sources are ET)
    DateTime.new(
      Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
      Time.new!(String.to_integer(hour), String.to_integer(min), String.to_integer(sec)),
      "America/New_York"
    )
    |> case do
      {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      err -> err
    end
  rescue
    _ -> :error
  end

  defp parse_dt(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>) do
    DateTime.new(
      Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
      ~T[00:00:00],
      "America/New_York"
    )
    |> case do
      {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      err -> err
    end
  rescue
    _ -> :error
  end

  defp parse_dt(_), do: :error

  defp unescape(nil), do: nil

  defp unescape(value) do
    value
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\\\", "\\")
  end

  defp generate_uid(summary, dt, source) do
    raw = "#{source}|#{summary}|#{DateTime.to_iso8601(dt)}"
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    "#{hash}@tricities-events"
  end

  # --- generation ---

  defp event_to_vevent(%Event{vevent_block: block, source: source})
       when is_binary(block) and block != "" do
    apply_tag_to_block(block, Map.get(@source_tags, source))
  end

  defp event_to_vevent(%Event{} = event) do
    tagged_summary = apply_tag(event.summary, Map.get(@source_tags, event.source))

    lines = [
      "BEGIN:VEVENT",
      "UID:#{event.uid}",
      "DTSTAMP:#{format_utc(DateTime.utc_now())}",
      "DTSTART:#{format_utc(event.starts_at)}",
      maybe("DTEND", event.ends_at && format_utc(event.ends_at)),
      "SUMMARY:#{escape(tagged_summary)}",
      maybe("DESCRIPTION", event.description && escape(event.description)),
      maybe("LOCATION", event.location && escape(event.location)),
      maybe("URL", event.url),
      "X-SOURCE:#{event.source}",
      "END:VEVENT"
    ]

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
  end

  defp apply_tag(summary, nil), do: summary

  defp apply_tag(summary, tag) do
    prefix = "[#{tag}] "
    if String.starts_with?(summary, prefix), do: summary, else: prefix <> summary
  end

  # Rewrite the SUMMARY line of a passthrough VEVENT block to prepend the
  # org tag. SUMMARY lines may carry RFC 5545 parameters (e.g.
  # `SUMMARY;LANGUAGE=en:Foo`) so we match on the property name + any
  # parameters, then prepend the tag to the value.
  defp apply_tag_to_block(block, nil), do: block

  defp apply_tag_to_block(block, tag) do
    prefix = "[#{tag}] "

    Regex.replace(
      ~r/^(SUMMARY(?:;[^:\r\n]*)?:)(.*)$/m,
      block,
      fn _full, head, value ->
        if String.starts_with?(value, prefix), do: head <> value, else: head <> prefix <> value
      end
    )
  end

  defp maybe(_key, nil), do: nil
  defp maybe(_key, ""), do: nil
  defp maybe(key, value), do: "#{key}:#{value}"

  defp format_utc(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")

    :io_lib.format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [
      dt.year,
      dt.month,
      dt.day,
      dt.hour,
      dt.minute,
      dt.second
    ])
    |> IO.iodata_to_binary()
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end
end
