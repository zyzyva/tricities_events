defmodule TricitiesEvents.Newsletter.Cache do
  @moduledoc """
  Per-email cache of extracted newsletter items (the raw Groq output), keyed by
  JMAP email id. The aggregator is stateless and re-runs every few hours over a
  rolling window of mail; without this cache it would re-run Groq on every
  already-seen newsletter each time. We only call Groq for emails we haven't
  extracted before.

  Stored as JSON at `priv/newsletter_cache.json` (override with NEWSLETTER_CACHE_PATH).
  """

  @default_path "priv/newsletter_cache.json"

  @doc "Load the cache as %{email_id => [item_map]} (empty map if absent/corrupt)."
  def load(path \\ path()) do
    with {:ok, bin} <- File.read(path),
         {:ok, map} when is_map(map) <- JSON.decode(bin) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Persist the cache map, creating the directory if needed."
  def save(map, path \\ path()) when is_map(map) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, JSON.encode!(map))
    map
  end

  defp path, do: System.get_env("NEWSLETTER_CACHE_PATH") || @default_path
end
