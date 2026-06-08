defmodule TricitiesEvents.Sources.Newsletter do
  @moduledoc """
  Source: chamber newsletters that publish events only by email (and usually only
  inside schedule images) — e.g. the Elizabethton chamber, whose website calendar
  is empty. Pulls recent newsletters from Fastmail (forwarded to a dedicated alias)
  and extracts events with Groq vision.

  Falls back to {:ok, []} when no events extract, and {:error, _} when the Fastmail
  token is missing — the aggregator treats that as a graceful zero-event source.
  """

  @behaviour TricitiesEvents.Source

  alias TricitiesEvents.Newsletter.{Cache, Extractor, Jmap}

  # Groq rate-limits above ~3 concurrent; only uncached (new) emails are extracted.
  @concurrency 3

  @impl true
  def name, do: "Chamber Newsletters"

  @impl true
  def multi_region?, do: false

  @impl true
  def fetch do
    case Jmap.recent_newsletters() do
      {:ok, emails} ->
        items_by_id = resolve_items(emails)

        events =
          emails
          |> Enum.flat_map(fn email ->
            Extractor.to_events(Map.get(items_by_id, email.id, []), email)
          end)
          |> dedupe_by_slot()

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Use cached extraction for seen emails; run Groq only on new ones. The cache is
  # pruned up front to this run's emails (can't grow unbounded) and persisted after
  # EACH successful extraction — so partial progress survives a timeout. That
  # matters in CI, where the cache starts cold and the source may be killed at the
  # aggregator's per-source timeout; it then self-heals over subsequent runs.
  # Failed extractions are not cached, so they retry.
  defp resolve_items(emails) do
    base = Cache.load() |> Map.take(Enum.map(emails, & &1.id))

    emails
    |> Enum.reject(&Map.has_key?(base, &1.id))
    |> Task.async_stream(fn e -> {e.id, Extractor.extract_items(e)} end,
      max_concurrency: @concurrency,
      timeout: 80_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(base, fn
      {:ok, {id, {:ok, items}}}, acc -> acc |> Map.put(id, items) |> Cache.save()
      _, acc -> acc
    end)
  end

  # Collapse the same event arriving from two newsletters under different titles
  # (e.g. "Network at 9" vs "Chamber Networking") by start time + venue.
  defp dedupe_by_slot(events) do
    Enum.uniq_by(events, fn e ->
      venue =
        e.location
        |> to_string()
        |> String.split(",")
        |> List.first()
        |> to_string()
        |> String.trim()
        |> String.downcase()

      {DateTime.to_iso8601(e.starts_at), venue}
    end)
  end
end
