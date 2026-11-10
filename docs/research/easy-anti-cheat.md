# Easy Anti-Cheat: Rust

Rust (Facepunch Studios, Steam app 252490) ships Easy Anti-Cheat in its Epic Online Services
flavour. propnix launches `RustClient.exe`, which Facepunch documents as the game without the EAC
wrapper, rather than `Rust.exe`, which is EAC's bootstrapper. The consequence is fixed by the
vendor: only EAC-unsecure servers are reachable, and they are joined by IP from the in-game console.
This page records what the payload shows about EAC, why the bootstrapper cannot run under wine, what
the EAC-free client still carries, and the network traffic the package accepts by running online.
The client is verified to the main menu (x86_64, 2026-09-03); joining a server is not verified.

## `Rust.exe` is EAC's bootstrapper

`strings` on `Rust.exe` shows the EAC launcher, not the game:
`AntiCheatLauncher@launcher@easyanticheat`, `EAC_ProtectedGameLaunchResult`, "Could not reach the
Easy Anti-Cheat CDN!", and the module CDN template

    https://modules-cdn.eac-prod.on.epicgames.com/modules/{{productid}}/{{deploymentid}}/{{system}}

`EasyAntiCheat/Settings.json` names the game it wraps, `"executable": "RustClient.exe"`, and sets
`"wait_for_game_process_exit": "false"`: the bootstrapper is designed to exit while the game keeps
running.

The depot's Steam install script (`win_installscript.vdf`) runs

    EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe install 429c2212ad284866aee071454c2125b5

whose job on Windows is to register EAC's kernel-mode service. propnix never runs a Steam install
script, and wine has no NT kernel to install a driver into.

Launching `Rust.exe` would therefore:

1. require network access to Epic's module CDN before the game starts;
2. try to load an anti-cheat module wine cannot host;
3. hand the launcher a stub process that exits while the game runs on, the primary-child teardown
   trap that also makes Skyrim SE launch `SkyrimSE.exe` rather than `SkyrimSELauncher.exe`.

`rust.apply { exe = "Rust.exe"; }` shows the bootstrapper failing.

## `RustClient.exe` is the game

`RustClient.exe` is the Unity player: PE32+, and its only non-KERNEL32 import is `UnityPlayer.dll`'s
`UnityMain2` (`readpe -i`). It reads `RustClient_Data/` beside itself, the standard Unity layout.

Launching it directly is the vendor-documented way to run Rust without EAC. Facepunch's support
article "Launching Rust with EAC disabled (RustClient.exe)" says:

> RustClient.exe is the Rust game application without the EAC wrapper. Launching this will be the
> same as Rust but without EAC, this means you will only be able to connect to unsecure servers.

(support.facepunchstudios.com/hc/en-us/articles/15041503601437, retrieved 2026-09-03)

There is no client-side flag: no launch argument, environment variable or config entry for running
without EAC appears in the payload or in Facepunch's documentation. The mechanism is which
executable starts.

## What the EAC-free client can reach

The same article:

> Launching Rust with EAC disabled means that you will only be able to connect to EAC-unsecure
> servers. These servers will not display in the server browser.

An in-game server browser empty of them is the documented behaviour. Connection is by IP, from the
F1 console:

    connect <ip>:<port>

Facepunch run an unsecure server for this purpose and print its address in that article:
`connect 79.137.98.20:28021`. Community servers join the class by setting `server.secure 0` /
`server.eac 0` server-side (widely documented by Rust hosting providers; not verifiable from the
payload).

Server authentication is a Steam ticket the server validates against Valve. propnix's offline Steam
shim (gbe_fork) answers ownership questions only and issues no such ticket, so it is not a route
around the online requirement (see [steam-entitlement.md](steam-entitlement.md)).

## The client still carries the anti-cheat SDK

`RustClient_Data/Plugins/x86_64/EOSSDK-Win64-Shipping.dll` ships, and `GameAssembly.dll` contains 50
`EOS_AntiCheat{Client,Server}_*` symbol names. Those are runtime P/Invoke targets, not import-table
entries: `objdump -x GameAssembly.dll` lists only KERNEL32, USER32, ADVAPI32, ole32, OLEAUT32,
SHELL32, WS2_32 and IPHLPAPI, the WinRT `api-ms-win-*` set, bcrypt, dbghelp and `baselib.dll`.
Nothing forces an anti-cheat session at load time, and `RustClient.exe` itself carries zero
`EOS_AntiCheat` strings. Whether the client calls `EOS_AntiCheatClient_BeginSession` is a runtime
decision the game makes per connection; on an unsecure server the vendor's article says it does not
need to.

## Network traffic with `online = true`

Rust has no single-player mode, no offline campaign and no local server in the client depot; the
product is connecting to a Facepunch or community server. propnix's usual guarantee, that the kernel
(a network namespace) rather than the app keeps a game from phoning home, does not apply to this
package. With `online = false` the client is loopback-only: the server browser comes up empty, every
connect fails, and the menu fills with `ConnectFailure (Network is unreachable)` from the Discord
friend provider and `api.facepunch.com`.

With the network reachable, the payload uses it:

- EAC/EOS telemetry: `api.epicgames.dev/telemeter/...` and
  `datarouter.ol.epicgames.com/datarouter/api/v1/public/data`, both string-visible in `Rust.exe`;
- Facepunch's own analytics: `Facepunch.Rust.AnalyticsManager` in `GameAssembly.dll`;
- the Steam and Discord SDKs the client bundles;
- Unity telemetry: `Player.log` carries three `Curl error 6: Could not resolve host` lines naming
  `config.uca.cloud.unity3d.com` and `cdp.cloud.unity3d.com`. Neither resolves on the host either,
  while `api.epicgames.dev` and `github.com` do: dead Unity endpoints, not a sandbox fault.
