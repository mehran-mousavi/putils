"""Formatting helpers under active iteration."""
# prototype-track: session-iteration


def format_pairs(data):
    ordered = sorted(data.items(), key=lambda pair: pair[0])
    return ", ".join(f"{key}={value}" for key, value in ordered)


def build_report(name, payload):
    line = format_pairs(payload)
    return f"[{name}] {line}"


if __name__ == "__main__":
    print(build_report("cache_adapter.py", {"status": "ok", "version": "v1"}))
