# One source tree, multiple personal builds

`Config.example.json` contains public defaults. `Tools/configure.py` overlays `Config.local.json` if it exists, or an explicitly supplied file:

```sh
python3 Tools/configure.py --config /path/to/private/personal.json
xcodegen generate
```

The generated Xcode project, plists and assets are ignored by Git. Run the generator again when switching configurations; do not edit generated files. To return to public defaults, pass `--config Config.example.json` explicitly (otherwise an existing local configuration is picked up).

| Key | Purpose |
| --- | --- |
| `app_name` | Home-screen name, widget name, CallKit fallback and Siri application name |
| `bundle_id` | iPhone bundle ID; Watch, widget and test IDs derive from it |
| `development_team` | Your 10-character Apple development team ID |
| `signing` | `automatic` (default) or `manual` |
| `provisioning_profile` | Profile specifier for manual signing; empty for automatic |
| `siri_aliases` | Up to three alternative app names, for example `Dot` |
| `accent_hex` | Six-digit RGB accent colour |
| `app_icon` | 1024×1024 PNG; `null` uses the included default |
| `avatar` | PNG artwork for the app and widget; `null` uses the default |
| `default_agent_page` | Optional page URL/UUID prefilled in setup; empty by default |
| `url_scheme` | Stable app link scheme; `dotwatch` by default |
| `widget_kind` | Stable WidgetKit identity; `DotCall` by default |

Image paths resolve relative to the configuration file. Store personal artwork beside an external config, or in an ignored private directory. Do not replace the committed public artwork for a personal build. Use a 1024×1024 opaque app icon. The widget decodes a small thumbnail at runtime to stay within WidgetKit's image limits.

The connected Dot's actual name can appear inside the app after sign-in. App name/icon/Siri aliases are build configuration; they do not change automatically from account data.

For scripted device builds:

```sh
DOTWATCH_CONFIG=/path/to/private/personal.json bash Tools/build.sh
```

Optional `DOTWATCH_BUILD_DIR` controls DerivedData and `DOTWATCH_CONFIGURATION` selects Debug or Release. With manual signing, the configured profile must cover all three app IDs. Xcode can manage separate profiles with automatic signing.

The generator assigns the icon to both iOS and watchOS explicitly. After compiling, `Tools/build.sh` checks that both installed app bundles contain primary-icon metadata and a compiled icon image. A missing icon fails the build check instead of silently producing a blank app icon.

The iPhone and Watch derive the Keychain service from the root bundle ID. Retaining that ID, the signing team, URL scheme and widget kind preserves the intended upgrade identity. Do not share a bundle ID between public demo and personal installations.

Configuration is for branding and build identity, **not credentials**. Tokens, passwords and cookies are not supported configuration fields. The page ID and signing identity may still be personal information; keep them out of commits and release archives.
