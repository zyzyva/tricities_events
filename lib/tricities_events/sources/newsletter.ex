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

  alias TricitiesEvents.Newsletter.{Extractor, Jmap}

  @impl true
  def name, do: "Chamber Newsletters"

  @impl true
  def multi_region?, do: false

  @impl true
  def fetch do
    case Jmap.recent_newsletters() do
      {:ok, emails} ->
        events =
          emails
          |> Task.async_stream(&extract/1,
            max_concurrency: 5,
            timeout: 80_000,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, events} -> events
            _ -> []
          end)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract(email) do
    case Extractor.extract(email) do
      {:ok, events} -> events
      _ -> []
    end
  end
end
