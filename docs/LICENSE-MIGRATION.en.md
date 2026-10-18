# License migration options

[中文](./LICENSE-MIGRATION.md) · [English](./LICENSE-MIGRATION.en.md)

> Current state: [LICENSE](../LICENSE) is a custom "non-commercial learning and research" license, which GitHub detects as `Other / NOASSERTION`.
> This document compares options and lists steps; it is not legal advice.

## Why it is worth changing

The current license says outright "It is not an open-source license" and only permits sharing **unmodified** copies. Consequences:

- Forking and opening a PR sits in a legal grey zone — you can accept a PR, but the contributor has no clear permission to distribute a modified copy.
- F-Droid / IzzyOnDroid require a free license; they cannot host it.
- Most awesome lists require open source; it is unlikely to be accepted.
- Schools, clubs and companies dare not use it in classes or internal workflows.
- GitHub's license filter cannot classify it, losing a discovery channel.

Good news: `git log --format='%an <%ae>' | sort -u` shows a single copyright holder today, so migration is cheapest now. **Once outside code contributions exist, migration requires asking every contributor.**

## Three options

| | Status quo | PolyForm Noncommercial 1.0.0 | AGPL-3.0 |
|---|---|---|---|
| OSI-approved open source | No | No | Yes |
| Recognised by GitHub | No (Other) | Yes | Yes |
| Accepts code PRs | Grey area | Yes | Yes |
| F-Droid / IzzyOnDroid | No | No | Yes |
| Most awesome lists | Very unlikely | Very unlikely | Yes |
| Prevents closed-source commercial use | Yes | Yes | Yes (including SaaS, but source must be shared) |
| Prevents "entering competitions with it" | Yes | No | No |
| Community trust | Low | Medium | High |

Key trade-off: **AGPL cannot stop someone from using your code in a competition or building a competitor; it can only require them to open-source their changes.** If "don't let it be taken to competitions or sold" matters most, you give up awesome lists, F-Droid and most code contributors. You cannot have both.

A middle ground: **AGPL-3.0 for code, trademark on the brand** (name, icon, social preview), with a README note that competition or commercial use should be discussed first. A trademark stops others from publishing under your name, but not from using the code.

## Migration steps (AGPL-3.0 as the example)

1. **Confirm the copyright holder**: `git log --format='%an <%ae>' | sort -u`. Currently only `duanbaiyang25@mails.ucas.ac.cn`.
2. **Use the official text**: take `LICENSE` from <https://www.gnu.org/licenses/agpl-3.0.txt>; do not edit the body by hand.
3. **Add a `NOTICE`**: state the code license, that the brand is not licensed, and the separate licenses/attribution for third-party data (Hipparcos / Gaia DR3).
4. **Update the storefront**: license badge and license section in README / README.en.md, release notes.
5. **Record it in CHANGELOG**: `license: migrate to AGPL-3.0 from vX.Y.Z`.
6. **No retroactive change**: old tags and APKs remain under the old license; the new one applies from the next release.
7. **Contribution grant**: `CONTRIBUTING.md` / `CONTRIBUTING.en.md` already include a clause allowing contributions to be distributed under the current or a future license, so the next migration is not blocked.
8. **Optional dual licensing**: AGPL plus a commercial license, leaving a paid path for closed-source integrators.
9. **Check dependencies and data**: Flutter/Dart packages are mostly BSD/MIT and compatible; star catalogues and deep-sky data may carry their own attribution or share-alike terms that a code license cannot override — list them in `NOTICE`.

## Recommendation

- Want a community, contributors, awesome lists and F-Droid → **AGPL-3.0**.
- Only want to share narrowly and refuse redistributed modified versions → keep the status quo, but lower expectations to "testers + translators + sample photos" and do not count on code contributors.
- Whichever you choose, say it in one sentence in the README so users do not have to guess.

## If you want to keep "non-commercial" with clearer terms

`PolyForm Noncommercial 1.0.0` is SPDX-recognised standard text and easier for institutions to accept than a bespoke license; but it is still not open source, and F-Droid and most awesome lists still will not take it. It suits the case "I explicitly do not want commercial use, but I want readable, recognisable terms".
