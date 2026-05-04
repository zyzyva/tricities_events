defmodule TricitiesEvents.Region do
  @moduledoc """
  Defines what counts as "Tri-Cities" for the aggregator and provides
  a fast filter that decides if an event belongs in the regional feed.

  The filter is fuzzy by design — sources publish locations in
  inconsistent formats. We accept any event whose location string
  contains one of our recognized cities or the explicit state codes,
  case-insensitively.
  """

  alias TricitiesEvents.Event

  # Cities and townships within ~40 miles of Elizabethton, TN
  @tri_cities_keywords [
    # TN cities
    "elizabethton",
    "johnson city",
    "kingsport",
    "bristol, tn",
    "bristol tn",
    "greeneville",
    "erwin",
    "unicoi",
    "jonesborough",
    "hampton, tn",
    "watauga",
    "milligan",
    "rogersville",
    "mountain city",
    "roan mountain",
    "limestone, tn",
    "afton, tn",
    "chuckey",
    "blountville",
    # VA cities (south of Bristol)
    "bristol, va",
    "bristol va",
    "abingdon",
    "marion, va",
    "glade spring"
  ]

  @blocked_keywords [
    # Other regions Incredible Towns aggregates that we don't want
    "asheville",
    "knoxville",
    "chattanooga",
    "nashville",
    "memphis",
    "raleigh",
    "charlotte"
  ]

  @doc "Return true if the event location appears to be in the Tri-Cities region."
  def in_region?(%Event{location: nil}), do: false
  def in_region?(%Event{location: ""}), do: false

  def in_region?(%Event{location: location}) do
    normalized = String.downcase(location) <> " "

    cond do
      Enum.any?(@blocked_keywords, &String.contains?(normalized, &1)) -> false
      Enum.any?(@tri_cities_keywords, &String.contains?(normalized, &1)) -> true
      true -> false
    end
  end
end
