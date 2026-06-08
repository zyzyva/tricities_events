// Cloudflare Pages Function (route: /feed) — serves the Tri-Cities calendar,
// optionally filtered to selected sources via  /feed?sources=slug1,slug2
// (Content-Type drives calendar apps; downloads still get a .ics filename.)
//
// Slugs are the source slugs from sources.json (and X-SOURCE on each VEVENT). The
// slugify here MUST match Aggregator.source_slug/1 in the Elixir app.
// No ?sources → the full master feed.

export async function onRequest(context) {
  const url = new URL(context.request.url);

  // The master feed is a static asset on the same origin.
  const master = await fetch(new URL("/tricities-events.ics", url.origin), {
    cf: { cacheTtl: 300 },
  });
  if (!master.ok) return new Response("upstream feed unavailable", { status: 502 });

  let ics = await master.text();

  const param = url.searchParams.get("sources");
  if (param !== null) {
    const wanted = new Set(
      param.split(",").map(slugify).filter(Boolean)
    );
    ics = filterBySources(ics, wanted);
  }

  return new Response(ics, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      "cache-control": "public, max-age=900",
      "access-control-allow-origin": "*",
      "content-disposition": 'inline; filename="tricities-events.ics"',
    },
  });
}

function slugify(s) {
  return (s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

// Keep VCALENDAR header/footer; keep only VEVENT blocks whose X-SOURCE slug is in `wanted`.
function filterBySources(ics, wanted) {
  const out = [];
  let block = null;
  let blockSource = null;

  // Normalize any stray CRs so line matching is exact, then re-emit clean CRLF.
  for (const line of ics.replace(/\r/g, "").split("\n")) {
    if (line === "BEGIN:VEVENT") {
      block = [line];
      blockSource = null;
      continue;
    }
    if (block) {
      block.push(line);
      if (line.startsWith("X-SOURCE:")) {
        blockSource = slugify(line.slice("X-SOURCE:".length).trim());
      }
      if (line === "END:VEVENT") {
        if (blockSource && wanted.has(blockSource)) out.push(...block);
        block = null;
      }
      continue;
    }
    out.push(line); // VCALENDAR header / footer
  }

  return out.join("\r\n");
}
