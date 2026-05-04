defmodule TricitiesEvents.RegionTest do
  use ExUnit.Case, async: true

  alias TricitiesEvents.{Event, Region}

  defp event(location) do
    %Event{
      uid: "x",
      source: "Test",
      summary: "Test event",
      starts_at: ~U[2026-05-05 14:00:00Z],
      location: location
    }
  end

  test "accepts events in known Tri-Cities cities" do
    assert Region.in_region?(event("Spark Plaza, 404 South Roan Street, Johnson City, TN"))
    assert Region.in_region?(event("615 E Elk Ave, Elizabethton, TN 37643"))
    assert Region.in_region?(event("Tennessee Hills Distillery, Bristol, TN"))
    assert Region.in_region?(event("Downtown Kingsport"))
    assert Region.in_region?(event("100 Main St, Erwin, TN"))
    assert Region.in_region?(event("Some venue in Abingdon, VA"))
  end

  test "rejects events in other regions even with TN/VA suffix" do
    refute Region.in_region?(event("100 Main St, Knoxville, TN"))
    refute Region.in_region?(event("Asheville, NC"))
    refute Region.in_region?(event("Chattanooga venue, TN"))
    refute Region.in_region?(event("Nashville, TN"))
    refute Region.in_region?(event("Guild, TN"))
  end

  test "rejects events with no location" do
    refute Region.in_region?(event(nil))
    refute Region.in_region?(event(""))
  end
end
