import re
import sys


def slugify(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    return value.strip("-")


def main() -> None:
    text = " ".join(sys.argv[1:])
    print(slugify(text))


if __name__ == "__main__":
    main()
