# Vinted Scout

On-demand Vinted bargain scan for media resellers. Tap **Scan** and the app:

1. Reads the newest Vinted listings for each configured search (default: Blu-ray, CD, cassette tape; 2 pages each; New with tags / New without tags / Very good).
2. Asks Claude to pick the listings worth comping (box sets, boutique labels, collector steelbooks, sealed vintage cassettes…), skipping commons, DVDs, vague titles and retail-price sellers.
3. Pulls the real eBay **Sold Items** search for each candidate (never Terapeak), including delivery charges.
4. Asks Claude to list the comps newest-first, read the trend (newest sales rule, not the median) and give a verdict.
5. Deal = current eBay selling level ≥ 2 × landed cost **and** ≥ $15 above it. Landed cost = Vinted "incl." price + assumed shipping (default $5; $0 when the listing is free-ship).

Nothing is bought, offered or messaged. Every card has **Open on Vinted** and **eBay sold** buttons.

## Mojo Comps (price check one listing)
Android: on any eBay or Vinted listing tap **Share → Mojo Comps** (or tap the price-check icon on the home screen and paste a link / eBay item number). The app:

1. Opens the listing (follows ebay.us short links) and reads the page plus the seller description.
2. Asks Claude for the cost (price/current bid + shipping), every title in the lot, an exact eBay Sold search per title, and red flags (hate/NSBM media eBay bans, bootleg signs, DVD/CD lots, full screen, unnamed contents).
3. Pulls eBay **Sold Items** for each title (same edition/format/condition, buyer total incl. shipping, newest-sales trend).
4. Shows a per-item breakdown, total current selling level, a rough net after fees (13.6% + $0.40) and the $4.39 label, per-item landed cost against the under-$1/disc lot target, and a verdict (money maker = est. net ≥ 2× cost and ≥ $15 over it). A stop flag skips comps.

## Builds
GitHub Actions builds a Windows installer + portable zip and an Android APK on every push to `main`, attached to a release named `build-N`.

## Setup
Settings → paste an Anthropic API key (stored in the device's secure storage). Pick a model (`claude-sonnet-5-5` is cheap enough for a few cents per scan).

## Dev
```
flutter pub get
flutter run -d windows   # or an Android device
```
