# Fix nightlife scraper to reliably surface big clubs like Poppy, Sound, Delilah

## Problem
Big-name clubs (Poppy, Sound, Delilah, etc.) aren't showing up because the Discotech market page often fails to load, killing the only discovery path. Clubbable extraction is also too narrow. Google Events naturally favors Ticketmaster concert listings over club nights.

## What's changing

### 1. Multiple Discotech discovery fallback sources
- When the main market page (`discotech.me/los-angeles/`) fails, scrape these additional Discotech pages as fallback discovery sources:
  - **Guest lists page** (`/los-angeles/guest-lists/`) — lists clubs with active guest lists
  - **Bottle service page** (`/los-angeles/bottle-service/`) — lists clubs with bottle service
  - **Top clubs articles** (`app.discotech.me/articles/best-*-nightclubs-in-*`) — editorial venue lists
- Extract venue names and slugs from these pages, then fetch each venue's individual page for full details
- This ensures big clubs are always discovered even when the main listing page is blocked

### 2. Google Search-based nightlife venue discovery
- Add a new discovery channel that scrapes Google Search results for queries like `"best nightclubs in Los Angeles"`, `"top clubs in Los Angeles"`, `"nightlife venues Los Angeles"`
- Extract venue names from Google search result snippets
- Use extracted names to seed Discotech/Clubbable individual venue page lookups
- This is pure scraping — no hardcoded names — and reliably surfaces the biggest, most talked-about venues

### 3. Improved Clubbable URL extraction
- Broaden the regex pattern for extracting venue URLs from Clubbable market pages
- Add support for both PascalCase and lowercase slug formats
- Also scrape the Clubbable JSON-LD structured data (`"@type": "NightClub"` blocks) for venue names

### 4. Higher venue page limits
- Increase Discotech venue page limit from 18 → 32
- Increase Clubbable venue page limit from 16 → 28
- This ensures more venues are actually fetched and parsed, not just discovered

### 5. Apple Maps seed → aggregator enrichment loop
- When Apple Maps discovers a nightlife venue (e.g., "Poppy" via MKLocalSearch), automatically attempt to find and scrape its Discotech and Clubbable pages
- This creates a two-way pipeline: Apple Maps finds the venue exists, then aggregators provide the rich nightlife metadata

### 6. Google Events nightlife search improvements
- Add dedicated nightlife-focused search channels: `"club nights tonight in {city}"`, `"DJ events tonight in {city}"`, `"nightclub events {city}"`
- These queries surface more nightlife-specific results alongside the existing concert/event searches
- The Google Events scraper itself is functional and pushing data — it just needs better nightlife-targeted queries

## What stays the same
- No hardcoded venue names — everything is 100% scrape-driven
- All existing lighting, camera, and lookdev in the app
- Ticketmaster, Eventbrite, RunSignup, and StubHub scrapers unchanged
- All existing venue enrichment (Apple Maps media, official website, reservation providers)
- Existing cache, dedup, and merge logic
