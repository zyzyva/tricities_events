defmodule TricitiesEvents.ICalTest do
  use ExUnit.Case, async: true

  alias TricitiesEvents.ICal

  describe "parse/2" do
    test "parses a basic VEVENT with TZID-prefixed DTSTART" do
      ics = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      DTSTART;TZID=America/New_York:20260505T090000
      DTEND;TZID=America/New_York:20260505T100000
      UID:foo@example.com
      SUMMARY:ARM Ribbon Cutting
      LOCATION:123 Main St\\, Elizabethton\\, TN
      END:VEVENT
      END:VCALENDAR
      """

      [event] = ICal.parse(ics, "Test")
      assert event.uid == "foo@example.com"
      assert event.source == "Test"
      assert event.summary == "ARM Ribbon Cutting"
      assert event.location == "123 Main St, Elizabethton, TN"
      assert event.starts_at.year == 2026
      assert event.starts_at.month == 5
      # 09:00 ET == 13:00 UTC during DST
      assert event.starts_at.hour == 13
    end

    test "parses UTC timestamps marked with Z suffix" do
      ics = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART:20260505T140000Z
      UID:bar@example.com
      SUMMARY:UTC Event
      END:VEVENT
      END:VCALENDAR
      """

      [event] = ICal.parse(ics, "Test")
      assert event.starts_at.hour == 14
      assert event.starts_at.time_zone == "Etc/UTC"
    end

    test "skips events missing required fields" do
      ics = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:incomplete@example.com
      END:VEVENT
      END:VCALENDAR
      """

      assert ICal.parse(ics, "Test") == []
    end

    test "preserves raw vevent_block for passthrough" do
      ics = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART:20260505T140000Z
      UID:passthrough@example.com
      SUMMARY:Original
      X-CUSTOM-FIELD:keep-me
      END:VEVENT
      END:VCALENDAR
      """

      [event] = ICal.parse(ics, "Test")
      assert event.vevent_block =~ "X-CUSTOM-FIELD:keep-me"
      assert event.vevent_block =~ "SUMMARY:Original"
    end

    test "unfolds RFC 5545 line continuations" do
      # Per RFC 5545 §3.1, unfolding strips CRLF + leading WSP entirely.
      # Encoders preserve content spaces by including them in the line
      # before the fold (note the trailing space before \r\n below).
      ics =
        "BEGIN:VCALENDAR\r\n" <>
          "BEGIN:VEVENT\r\n" <>
          "DTSTART:20260505T140000Z\r\n" <>
          "UID:fold@example.com\r\n" <>
          "SUMMARY:This is a long \r\n title that wraps\r\n" <>
          "END:VEVENT\r\n" <>
          "END:VCALENDAR\r\n"

      [event] = ICal.parse(ics, "Test")
      assert event.summary == "This is a long title that wraps"
    end
  end

  describe "generate/1" do
    test "wraps events in a VCALENDAR document" do
      events = [
        %TricitiesEvents.Event{
          uid: "abc@x.com",
          source: "Test",
          summary: "Sample",
          starts_at: ~U[2026-05-05 14:00:00Z],
          location: "Somewhere"
        }
      ]

      ics = ICal.generate(events)
      assert ics =~ "BEGIN:VCALENDAR"
      assert ics =~ "PRODID:-//TricitiesEvents//Aggregator//EN"
      assert ics =~ "BEGIN:VEVENT"
      assert ics =~ "UID:abc@x.com"
      assert ics =~ "SUMMARY:Sample"
      assert ics =~ "DTSTART:20260505T140000Z"
      assert ics =~ "X-SOURCE:Test"
      assert ics =~ "END:VEVENT"
      assert ics =~ "END:VCALENDAR"
    end

    test "prefixes SUMMARY with a short org tag for known sources" do
      events = [
        %TricitiesEvents.Event{
          uid: "1@x.com",
          source: "Elizabethton Chamber",
          summary: "Members Breakfast",
          starts_at: ~U[2026-05-05 14:00:00Z]
        }
      ]

      ics = ICal.generate(events)
      assert ics =~ "SUMMARY:[Eliz Chamber] Members Breakfast"
    end

    test "does not tag Custom-source events (user-curated summaries)" do
      events = [
        %TricitiesEvents.Event{
          uid: "2@x.com",
          source: "Custom",
          summary: "BANQ Networking",
          starts_at: ~U[2026-05-05 14:00:00Z]
        }
      ]

      ics = ICal.generate(events)
      assert ics =~ "SUMMARY:BANQ Networking"
      refute ics =~ "[Custom]"
    end

    test "tags passthrough vevent_blocks by rewriting the SUMMARY line" do
      raw_block =
        "BEGIN:VEVENT\r\nDTSTART:20260505T140000Z\r\nUID:p@x.com\r\nSUMMARY:Members Breakfast\r\nX-MARKER:preserved\r\nEND:VEVENT"

      events = [
        %TricitiesEvents.Event{
          uid: "p@x.com",
          source: "Incredible Towns",
          summary: "Members Breakfast",
          starts_at: ~U[2026-05-05 14:00:00Z],
          vevent_block: raw_block
        }
      ]

      ics = ICal.generate(events)
      assert ics =~ "SUMMARY:[Incredible Towns] Members Breakfast"
      assert ics =~ "X-MARKER:preserved"
    end

    test "is idempotent — does not double-tag an already-tagged summary" do
      events = [
        %TricitiesEvents.Event{
          uid: "3@x.com",
          source: "Elizabethton Chamber",
          summary: "[Eliz Chamber] Members Breakfast",
          starts_at: ~U[2026-05-05 14:00:00Z]
        }
      ]

      ics = ICal.generate(events)
      refute ics =~ "[Eliz Chamber] [Eliz Chamber]"
      assert ics =~ "SUMMARY:[Eliz Chamber] Members Breakfast"
    end

    test "uses raw vevent_block when available" do
      raw_block =
        "BEGIN:VEVENT\r\nDTSTART:20260505T140000Z\r\nUID:raw@x.com\r\nSUMMARY:Raw\r\nX-MARKER:preserved\r\nEND:VEVENT"

      events = [
        %TricitiesEvents.Event{
          uid: "raw@x.com",
          source: "Test",
          summary: "Raw",
          starts_at: ~U[2026-05-05 14:00:00Z],
          vevent_block: raw_block
        }
      ]

      ics = ICal.generate(events)
      assert ics =~ "X-MARKER:preserved"
    end
  end
end
