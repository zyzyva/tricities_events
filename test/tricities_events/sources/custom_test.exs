defmodule TricitiesEvents.Sources.CustomTest do
  use ExUnit.Case, async: true

  alias TricitiesEvents.Sources.Custom

  defp write_tmp(json) do
    path = Path.join(System.tmp_dir!(), "custom_events_#{System.unique_integer([:positive])}.json")
    File.write!(path, json)
    path
  end

  describe "fetch_from/1" do
    test "returns empty list when file is missing" do
      assert {:ok, []} = Custom.fetch_from("/no/such/file.json")
    end

    test "returns empty list when file has no events" do
      path = write_tmp(~s({"events": []}))
      assert {:ok, []} = Custom.fetch_from(path)
    end

    test "parses a one-off event in America/New_York" do
      path =
        write_tmp(~s({
          "events": [
            {
              "summary": "Eggs & Issues Breakfast",
              "location": "MeadowView Conference Center, Kingsport, TN",
              "starts_at": "2099-06-10T07:30",
              "duration_minutes": 90
            }
          ]
        }))

      {:ok, [event]} = Custom.fetch_from(path)
      assert event.summary == "Eggs & Issues Breakfast"
      assert event.location =~ "Kingsport"
      assert event.source == "Custom"
      assert event.starts_at.year == 2099
      # 07:30 ET in June (EDT) → 11:30 UTC
      assert event.starts_at.hour == 11
      assert event.starts_at.minute == 30
      assert DateTime.diff(event.ends_at, event.starts_at, :minute) == 90
    end

    test "expands a weekly recurrence with byday into concrete instances" do
      path =
        write_tmp(~s({
          "events": [
            {
              "summary": "Weekly Coffee Networking",
              "location": "Cracker Barrel, Johnson City",
              "starts_at": "2099-06-01T07:00",
              "duration_minutes": 60,
              "recurrence": {
                "freq": "weekly",
                "byday": ["WE"],
                "count": 4
              }
            }
          ]
        }))

      {:ok, events} = Custom.fetch_from(path)
      assert length(events) == 4

      [first | _] = events
      # First Wednesday on or after 2099-06-01 is 2099-06-03
      assert first.starts_at.year == 2099
      assert first.starts_at.month == 6
      day_of_week = first.starts_at |> DateTime.to_date() |> Date.day_of_week()
      assert day_of_week == 3

      # All instances stable + unique UIDs
      uids = Enum.map(events, & &1.uid)
      assert length(Enum.uniq(uids)) == 4
    end

    test "expands monthly recurrence using nth-weekday byday like 1TU" do
      path =
        write_tmp(~s({
          "events": [
            {
              "summary": "First Tuesday Founders Lunch",
              "location": "Downtown",
              "starts_at": "2099-01-01T12:00",
              "duration_minutes": 60,
              "recurrence": {
                "freq": "monthly",
                "byday": "1TU",
                "count": 3
              }
            }
          ]
        }))

      {:ok, events} = Custom.fetch_from(path)
      assert length(events) == 3

      Enum.each(events, fn e ->
        date = DateTime.to_date(e.starts_at)
        assert Date.day_of_week(date) == 2
        assert date.day <= 7, "expected 1st Tuesday but got #{inspect(date)}"
      end)
    end

    test "stops at the until date when provided" do
      path =
        write_tmp(~s({
          "events": [
            {
              "summary": "Bounded Series",
              "starts_at": "2099-01-01T09:00",
              "duration_minutes": 60,
              "recurrence": {
                "freq": "weekly",
                "byday": ["MO"],
                "until": "2099-01-31"
              }
            }
          ]
        }))

      {:ok, events} = Custom.fetch_from(path)
      # 4 Mondays in January 2099 (5, 12, 19, 26)
      assert length(events) == 4
      latest = Enum.max_by(events, & &1.starts_at, DateTime)
      assert Date.compare(DateTime.to_date(latest.starts_at), ~D[2099-01-31]) in [:lt, :eq]
    end

    test "preserves local wall-clock time across DST transitions" do
      # Weekly Tuesday at 9:00 AM ET starting in EDT (June). Within the
      # ~365-day horizon we should see both EDT (June, UTC-4 → 13:00 UTC)
      # and EST (December, UTC-5 → 14:00 UTC) instances.
      path =
        write_tmp(~s({
          "events": [
            {
              "summary": "DST stability check",
              "starts_at": "2099-06-02T09:00",
              "duration_minutes": 60,
              "recurrence": {"freq": "weekly", "byday": ["TU"], "count": 40}
            }
          ]
        }))

      {:ok, events} = Custom.fetch_from(path)

      summer = Enum.find(events, &(&1.starts_at.month in 6..7))
      winter = Enum.find(events, &(&1.starts_at.month in 12..12))

      assert summer.starts_at.hour == 13, "EDT 09:00 should be 13:00 UTC"
      assert winter.starts_at.hour == 14, "EST 09:00 should be 14:00 UTC"
    end

    test "produces stable UIDs across runs for the same spec" do
      json = ~s({
        "events": [
          {
            "summary": "Stable Event",
            "starts_at": "2099-04-01T08:00",
            "duration_minutes": 30
          }
        ]
      })

      path1 = write_tmp(json)
      path2 = write_tmp(json)

      {:ok, [e1]} = Custom.fetch_from(path1)
      {:ok, [e2]} = Custom.fetch_from(path2)

      assert e1.uid == e2.uid
    end
  end
end
