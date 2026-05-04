# Tri-Cities Events Aggregator

Pulls events from multiple Tri-Cities (TN/VA) Chamber of Commerce, networking, and entrepreneur organizations into a single subscribable iCal feed.

## Sources

| Source | Type | Status |
|---|---|---|
| Elizabethton Chamber of Commerce | iCal feed (Tribe) | ✅ |
| Incredible Towns / IBN | iCal feed (MEC) — region-filtered | ✅ |
| Unicoi County Chamber | iCal feed (Tribe) | ⚠️ Plugin currently misbehaving server-side |
| FoundersForge | HTML scrape | ✅ |
| Johnson City Chamber | ChamberMaster | TODO — needs scraper |
| Kingsport Chamber | ChamberMaster | TODO |
| Bristol Chamber | ChamberMaster | TODO |
| Greene County Partnership | ChamberMaster | TODO |

## Usage

```bash
mix deps.get
mix tricities.refresh
```

Output is written to `priv/static/tricities-events.ics`. Host that file on any static service (Cloudflare Pages, GitHub Pages, S3, etc.) and people can subscribe via:

```
webcal://your-host/tricities-events.ics
```

## Architecture

- **`TricitiesEvents.Source`** — behaviour every source implements
- **`TricitiesEvents.Sources.*`** — one module per source, returns `[%Event{}]`
- **`TricitiesEvents.ICal`** — minimal RFC 5545 parser/generator. iCal sources passthrough raw VEVENT blocks; HTML scrapers build VEVENTs from struct fields
- **`TricitiesEvents.Region`** — fuzzy location filter for multi-region sources (e.g. Incredible Towns publishes nationally; we keep only Tri-Cities events)
- **`TricitiesEvents.Aggregator`** — fans out to all sources in parallel, dedupes by `summary|starts_at|location`, drops past events, writes the master `.ics`

## Adding a source

1. Create `lib/tricities_events/sources/your_source.ex` implementing `TricitiesEvents.Source`
2. Add the module to `@default_sources` in `aggregator.ex`
3. If the source publishes outside Tri-Cities, add `def multi_region?, do: true`

## Scheduling

Run `mix tricities.refresh` on a cron (every 1-6 hours is plenty — sources update slowly).

```cron
0 */4 * * * cd /path/to/tricities_events && /path/to/mix tricities.refresh
```
