# Licensing of this folder

`bar.html` and `styles.css` are adapted from the starter widget pack of
[Zebar](https://github.com/glzr-io/zebar) (`resources/starter/`), which is
licensed under the GNU General Public License v3.0. These two files remain under
GPL-3.0; see `COPYING`.

Changes from the original: the weather readout uses a `TEMP_UNIT` setting
(Fahrenheit by default) instead of always showing Celsius.

Everything else in this repository is MIT-licensed (see `/LICENSE`).

## vendor/

Third-party code bundled so the bar and its panels need no internet. Rebuild with
`vendor/build.ps1` at the repository root (pinned in `vendor/package.json`).

- `ui.mjs`: one minified bundle of [React and React DOM](https://github.com/facebook/react) 18.3.1 (MIT),
  [htm](https://github.com/developit/htm) 3.1.1 (Apache-2.0) and the
  [Zebar](https://github.com/glzr-io/zebar) 3.3.1 client library (GPL-3.0-only, see `COPYING`) with its
  dependencies @tauri-apps/api and plugin-dialog (MIT or Apache-2.0), glazewm (MIT), luxon (MIT) and zod (MIT).
  Their licence notices are at the end of the file.
- `nerd-fonts.css` and `nerd-fonts.woff2`: the [Nerd Fonts](https://www.nerdfonts.com) symbols web font
  and stylesheet (MIT; the icon sets inside keep their own licences, listed at nerdfonts.com).
