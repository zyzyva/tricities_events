defmodule TricitiesEvents.Sources.JohnsonCityChamberTest do
  use ExUnit.Case, async: true

  alias TricitiesEvents.Sources.JohnsonCityChamber

  describe "parse_listing_evtids/1" do
    test "extracts unique event IDs from the listing-page calendar grid" do
      html = """
      <div id="ccaId_divEvtInfo0430_143749" class="ccaEvtInfo">
        <div class="ccaEvtName">
          <a href="EvtListing.aspx?dbid2=TNJC&amp;evtid=143749&amp;class=E">Members Only Business After Hours</a>
        </div>
        <div class="ccaEvtTime">5:30 PM</div>
      </div>
      <div id="ccaId_divEvtInfo0513_143807" class="ccaEvtInfo">
        <div class="ccaEvtName">
          <a href="EvtListing.aspx?dbid2=TNJC&amp;evtid=143807&amp;class=E">Membership Breakfast</a>
        </div>
      </div>
      <!-- Mobile/desktop variants of the same event should not duplicate -->
      <div id="ccaId_divEvtInfo0513_143807_Mobile" class="ccaEvtInfo">
        <div class="ccaEvtName">
          <a href="EvtListing.aspx?dbid2=TNJC&amp;evtid=143807&amp;class=E">Membership Breakfast</a>
        </div>
      </div>
      """

      assert JohnsonCityChamber.parse_listing_evtids(html) == ["143749", "143807"]
    end
  end

  describe "parse_detail/2" do
    test "parses a typical event detail page with start and end time" do
      html = """
      <div class="ccaEvtListingEvtName ccaCustom">Members Only Business After Hours: Blackthorn Club</div>
      <div class="ccaEvtListingWhen ccaCustom">
        <span class="ccaEvtListingDetailLabel ccaCustom">When:</span>
        <div class="ccaEvtListingDetailText ccaCustom">Thursday, April 30, 2026 5:30 PM thru 07:30 PM</div>
      </div>
      <div class="ccaEvtListingWhere ccaCustom">
        <span class="ccaEvtListingDetailLabel ccaCustom">Where:</span>
        <div class="ccaEvtListingDetailText ccaCustom">Blackthorn Club <br />1501 Ridges Club Dr. <br />Jonesborough, TN 37659</div>
      </div>
      <div class="ccaEvtListingDesc ccaCustom">The Chamber is excited to partner with Blackthorn Club for a Members Only Business After Hours.</div>
      """

      {:ok, event} = JohnsonCityChamber.parse_detail(html, "143749")

      assert event.summary == "Members Only Business After Hours: Blackthorn Club"
      assert event.location == "Blackthorn Club, 1501 Ridges Club Dr., Jonesborough, TN 37659"
      assert event.description =~ "Members Only Business After Hours"
      assert event.url == "https://cca.johnsoncitytnchamber.com/EvtListing.aspx?dbid2=TNJC&evtid=143749&class=E"
      assert event.source == "Johnson City Chamber"

      # 5:30 PM ET on April 30, 2026 = 21:30 UTC (EDT, UTC-4)
      assert event.starts_at.year == 2026
      assert event.starts_at.month == 4
      assert event.starts_at.day == 30
      assert event.starts_at.hour == 21
      assert event.starts_at.minute == 30

      # 7:30 PM ET = 23:30 UTC
      assert event.ends_at.hour == 23
      assert event.ends_at.minute == 30
    end

    test "parses an event with only a start time (no 'thru')" do
      html = """
      <div class="ccaEvtListingEvtName">Membership Breakfast with Milligan</div>
      <div class="ccaEvtListingWhen">
        <span class="ccaEvtListingDetailLabel">When:</span>
        <div class="ccaEvtListingDetailText">Wednesday, May 13, 2026 7:00 AM</div>
      </div>
      <div class="ccaEvtListingWhere">
        <span class="ccaEvtListingDetailLabel">Where:</span>
        <div class="ccaEvtListingDetailText">Chamber Office</div>
      </div>
      """

      {:ok, event} = JohnsonCityChamber.parse_detail(html, "143807")
      assert event.summary == "Membership Breakfast with Milligan"
      # 7:00 AM EDT = 11:00 UTC
      assert event.starts_at.hour == 11
      assert event.starts_at.minute == 0
      assert event.ends_at == nil
    end

    test "returns :error when required fields can't be parsed" do
      assert {:error, _} = JohnsonCityChamber.parse_detail("<div>nothing useful</div>", "999")
    end

    test "produces a stable UID across runs for the same evtid" do
      html = """
      <div class="ccaEvtListingEvtName">Stable Event</div>
      <div class="ccaEvtListingWhen">
        <div class="ccaEvtListingDetailText">Wednesday, May 13, 2026 7:00 AM</div>
      </div>
      """

      {:ok, e1} = JohnsonCityChamber.parse_detail(html, "143807")
      {:ok, e2} = JohnsonCityChamber.parse_detail(html, "143807")
      assert e1.uid == e2.uid
    end
  end
end
