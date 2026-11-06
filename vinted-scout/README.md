# Vinted Scout

On-demand Vinted bargain scan for media resellers. Tap **Scan** and the app:

1. Reads the newest Vinted listings for each configured search (default: Blu-ray, CD, cassette tape; 2 pages each; New with tags / New without tags / Very good).
2. Asks Claude to pick the listings worth comping (box sets, boutique labels, collector steelbooks, sealed vintage cassettes…), skipping commons, DVDs, vague titles and retail-price sellers.
3. Pulls the real eBay **Sold Items** search for each candidate (never Terapeak), including delivery charges.
4. Asks Claude to list the comps newest-first, read the trend (newest sales rule, not the median) and give a verdict.
5. Deal = current eBay selling level ≥ 2 × landed cost **and** ≥ $15 above it. Landed cost = Vinted "incl." price + assumed shipping (default $5; $0 when the listing is free-ship).

Nothing is bought, offered or messaged. Every card has **Open on Vinted** and **eBay sold** buttons.

## Builds
GitHub Actions builds a Windows installer + portable zip and an Android APK on every push to `main`, attached to a release named `build-N`.

## Setup
Settings → paste an Anthropic API key (stored in the device's secure storage). Pick a model (`claude-sonnet-5-5` is cheap enough for a few cents per scan).

## Dev
```
flutter pub get
flutter run -d windows   # or an Android device
```
