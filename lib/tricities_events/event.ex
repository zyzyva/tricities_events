defmodule TricitiesEvents.Event do
  @moduledoc """
  Normalized event struct used internally and by HTML scrapers.

  iCal sources passthrough raw VEVENT blocks via `vevent_block` to avoid
  lossy parse/regenerate round-trips. HTML scrapers populate the
  structured fields and the generator builds VEVENT blocks from them.
  """

  @type t :: %__MODULE__{
          uid: String.t(),
          source: String.t(),
          summary: String.t(),
          description: String.t() | nil,
          location: String.t() | nil,
          url: String.t() | nil,
          starts_at: DateTime.t(),
          ends_at: DateTime.t() | nil,
          vevent_block: String.t() | nil
        }

  @enforce_keys [:uid, :source, :summary, :starts_at]
  defstruct [
    :uid,
    :source,
    :summary,
    :description,
    :location,
    :url,
    :starts_at,
    :ends_at,
    :vevent_block
  ]

  @doc "Build a stable dedup key from summary + start time + location fragment."
  def dedup_key(%__MODULE__{summary: summary, starts_at: starts_at, location: location}) do
    location_fragment =
      location
      |> to_string()
      |> String.split(",")
      |> List.first()
      |> Kernel.||("")
      |> String.trim()
      |> String.downcase()

    summary_normalized =
      summary
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9 ]/, "")
      |> String.trim()

    "#{summary_normalized}|#{DateTime.to_iso8601(starts_at)}|#{location_fragment}"
  end
end
