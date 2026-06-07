defmodule TricitiesEvents.Aggregator do
  @moduledoc """
  Orchestrates all sources, dedupes events, and writes the master
  Tri-Cities iCal file. Handles per-source failures gracefully — a
  broken source returns zero events, never blocks the run.
  """

  require Logger

  alias TricitiesEvents.{Event, ICal, Region}

  @default_sources [
    TricitiesEvents.Sources.ElizabethtonChamber,
    TricitiesEvents.Sources.IncredibleTowns,
    TricitiesEvents.Sources.UnicoiChamber,
    TricitiesEvents.Sources.FoundersForge,
    TricitiesEvents.Sources.JohnsonCityChamber,
    TricitiesEvents.Sources.Newsletter,
    TricitiesEvents.Sources.Custom
  ]

  @output_path "priv/static/tricities-events.ics"

  def run(opts \\ []) do
    sources = Keyword.get(opts, :sources, @default_sources)
    output_path = Keyword.get(opts, :output, @output_path)

    results =
      sources
      |> Task.async_stream(&fetch_with_report/1, timeout: 90_000, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{name: "unknown", count: 0, error: reason, events: []}
      end)

    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)

    all_events =
      results
      |> Enum.flat_map(& &1.events)
      |> Enum.filter(&(DateTime.compare(&1.starts_at, cutoff) != :lt))
      |> dedupe()
      |> Enum.sort_by(& &1.starts_at, DateTime)

    ics = ICal.generate(all_events)

    output_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(output_path, ics)

    manifest_path = write_manifest(all_events, output_path)

    %{
      total_events: length(all_events),
      sources: Enum.map(results, &Map.delete(&1, :events)),
      output_path: output_path,
      manifest_path: manifest_path
    }
  end

  # Emit sources.json next to the .ics: the list of sources actually present in
  # the published feed (with a URL-safe slug + future-event count). The website's
  # source-picker reads this to build its checkboxes, so new sources appear
  # automatically. The Pages function filters /feed.ics by these same slugs.
  defp write_manifest(events, output_path) do
    sources =
      events
      |> Enum.group_by(& &1.source)
      |> Enum.map(fn {name, evs} ->
        %{slug: source_slug(name), name: name, count: length(evs)}
      end)
      |> Enum.sort_by(& &1.name)

    manifest = %{updated: DateTime.utc_now() |> DateTime.to_iso8601(), sources: sources}
    path = Path.join(Path.dirname(output_path), "sources.json")
    File.write!(path, JSON.encode!(manifest))
    path
  end

  @doc "URL-safe source slug (must match the slugify in functions/feed.ics.js)."
  def source_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp fetch_with_report(source_module) do
    name = source_module.name()
    Logger.info("Fetching from #{name}...")

    case source_module.fetch() do
      {:ok, events} ->
        events = maybe_filter_by_region(events, source_module)
        Logger.info("  → #{length(events)} events from #{name}")
        %{name: name, count: length(events), error: nil, events: events}

      {:error, reason} ->
        Logger.warning("  ✗ #{name} failed: #{inspect(reason)}")
        %{name: name, count: 0, error: reason, events: []}
    end
  rescue
    err ->
      Logger.error("  ✗ #{source_module} crashed: #{Exception.message(err)}")
      %{name: to_string(source_module), count: 0, error: err, events: []}
  end

  defp maybe_filter_by_region(events, source_module) do
    if function_exported?(source_module, :multi_region?, 0) and source_module.multi_region?() do
      Enum.filter(events, &Region.in_region?/1)
    else
      events
    end
  end

  defp dedupe(events) do
    events
    |> Enum.group_by(&Event.dedup_key/1)
    |> Enum.map(fn {_key, group} -> List.first(group) end)
  end
end
