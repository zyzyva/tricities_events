// Cloudflare Pages advanced-mode Worker (_worker.js in the deploy root). Pages
// routes every request through this; static assets are served via env.ASSETS.
//
//   /feed?sources=slug1,slug2  -> master calendar filtered to those sources
//   /feed                      -> full calendar
//   *.ics                      -> static calendar files, forced text/calendar
//   everything else            -> static passthrough (index.html, sources.json…)
//
// Slugs come from sources.json / X-SOURCE; slugify here MUST match
// Aggregator.source_slug/1 in the Elixir app.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/feed") {
      const master = await env.ASSETS.fetch(new URL("/tricities-events.ics", url.origin));
      if (!master.ok) return new Response("upstream feed unavailable", { status: 502 });

      let ics = await master.text();
      const param = url.searchParams.get("sources");
      if (param !== null) {
        const wanted = new Set(param.split(",").map(slugify).filter(Boolean));
        ics = filterBySources(ics, wanted);
      }
      return calendar(ics);
    }

    // Keep direct .ics URLs (incl. the legacy /tricities-events.ics subscription)
    // served as calendars even though _worker.js bypasses the _headers file.
    if (url.pathname.endsWith(".ics")) {
      const asset = await env.ASSETS.fetch(request);
      return asset.ok ? calendar(await asset.text()) : asset;
    }

    return env.ASSETS.fetch(request);
  },
};

function calendar(ics) {
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
  return (s || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

// Keep VCALENDAR header/footer; keep only VEVENT blocks whose X-SOURCE slug ∈ wanted.
function filterBySources(ics, wanted) {
  const out = [];
  let block = null;
  let blockSource = null;

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
    out.push(line);
  }
  return out.join("\r\n");
}
