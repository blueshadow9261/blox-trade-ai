"""Collector configuration. Everything can be overridden with environment variables."""
import os

SCHEMA_VERSION = 1
SITE = "https://bloxfruitsvalues.gg"
RARITY_TIERS = ["mythical", "legendary", "rare", "uncommon", "common"]

USER_AGENT = os.environ.get(
    "COLLECTOR_USER_AGENT",
    "BloxTradeAI-Collector/1.0 (+set COLLECTOR_USER_AGENT with your contact URL/email)")
REQUEST_TIMEOUT = float(os.environ.get("COLLECTOR_TIMEOUT", "20"))
MIN_DELAY_SECONDS = float(os.environ.get("COLLECTOR_MIN_DELAY", "2.0"))
MAX_BODY_BYTES = 2_000_000

# Detail pages (permanent value, Robux price, exact value, revision date) are fetched
# only for fruits whose list entry changed, new fruits, and a few of the oldest others per run.
DETAIL_ROTATION_PER_RUN = int(os.environ.get("COLLECTOR_DETAIL_ROTATION", "3"))

# Validation thresholds
LARGE_CHANGE_PCT = 50.0          # single-run change that gets flagged needs_review
MAX_VALUE = 10 ** 13             # sanity ceiling
MIN_COUNT_RATIO = 0.7            # reject a snapshot with <70% of the previous fruit count
CONFLICT_TOLERANCE_PCT = 1.0     # cross-source disagreement tolerance for values
HISTORY_MAX_EVENTS = 1500

# Optional extra feeds: comma separated "name=https://url" of feeds in OUR normalized schema
# that you are permitted to use. Used only to surface conflicts; never averaged.
EXTRA_FEEDS = os.environ.get("COLLECTOR_EXTRA_FEEDS", "")
