"""Small utility prototype for iterative development."""
# prototype-track: session-iteration

from datetime import datetime


def normalize_items(items):
    return [item.strip().lower() for item in items if item and item.strip()]


def build_snapshot(items):
    clean = normalize_items(items)
    return {
        "count": len(clean),
        "items": clean[:5],
        "generated_at": datetime.utcnow().isoformat(timespec="seconds"),
    }


if __name__ == "__main__":
    sample = [" Alpha ", "beta", "", "GAMMA"]
    print(build_snapshot(sample))
