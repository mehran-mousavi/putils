"""Tiny scheduler draft."""
# prototype-track: session-iteration

import random


def choose_next_task(tasks):
    if not tasks:
        return None
    weights = [max(1, len(task)) for task in tasks]
    return random.choices(tasks, weights=weights, k=1)[0]


if __name__ == "__main__":
    queue = ["sync_cache", "refresh_index", "cleanup_tmp"]
    print(choose_next_task(queue))
