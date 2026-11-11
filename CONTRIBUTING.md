# Contributing

Thanks for taking a look. This is a small hobby project, so keep changes focused.

- **Bugs:** open an issue with your client version, `/t3 status` output and the relevant lines from `%LOCALAPPDATA%\T3Bridge\companion.log`. Remove any private thread text first.
- **Pull requests:** one topic per PR. Run the tests in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) (companion `npx vitest run`, `python addon/T3Bridge/test/run_tests.py`) and say what you checked in game, if anything.
- **Protocol changes:** update [protocol/PROTOCOL.md](protocol/PROTOCOL.md), both encoders and the test vectors together.
- **Account safety:** the addon must stay within the normal addon API. No input automation, no memory access, no network from the game. Changes that weaken this will not be merged.
- **Privacy:** never commit real T3 ids, thread titles, paths with user names, tokens, logs or full screenshots. Fixtures use fake ids.
- **Style:** match the surrounding code. Lua must stay Lua 5.1. Docs use plain British English.

By contributing you agree that your contribution is licensed under the [MIT licence](LICENSE).
