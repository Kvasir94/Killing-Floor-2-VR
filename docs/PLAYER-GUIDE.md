# KF2-VR player guide

KF2-VR runs your own copy of Killing Floor 2 in a PC VR headset (or on the
desktop). It is an early alpha fan project, not affiliated with Tripwire
Interactive. Expect bugs, and please report them.

## What you need

- **Windows 10 or 11.**
- **Killing Floor 2** on **Steam** or the **Epic Games Store**. Every player needs
  their own copy. Steam offers Solo, Host and Join in VR or on the desktop; Epic
  is experimental Solo VR only (see [Epic Games](#epic-games-experimental-solo-vr)).
- **A PC VR headset runtime** for VR play: SteamVR, Quest Link / Air Link,
  Virtual Desktop or your headset's own PC app, selected as the active OpenXR
  runtime. Desktop play works without one.

Python is included in the ZIP; you do not need to install anything else.
KF2-VR is matched to exact game builds. If your store updates Killing Floor 2,
the window says your copy doesn't match until a new KF2-VR release is out. Do
not copy files from an older ZIP to get around this.

## Installing

1. Right-click the ZIP and choose **Extract All**. Put it somewhere easy, such as
   Documents. Don't run it from inside the ZIP.
2. Open normal Killing Floor 2 from Steam or Epic once, then quit it.
3. Open **Start KF2-VR.cmd** in the extracted folder. That is the only file you
   need; leave the `app` folder alone.

## First launch

The first time on a PC, KF2-VR walks you through two steps, shown in the
sidebar:

1. **Your game** - if Killing Floor 2 is installed on both Steam and Epic, pick
   the copy to use (Steam is recommended; Epic is experimental Solo VR). If it
   wasn't found, open it once from its store, or choose its folder. The page
   also says whether your headset app (SteamVR, Quest Link, Virtual Desktop or
   your headset's PC app) is running; desktop play works without one.
2. **First-time setup** - dominant hand, seated mode, locomotion (smooth or
   teleport, snap or smooth turning), reload mode and graphics preset. Reload
   mode and graphics show their options as buttons with one line on what the
   chosen one does; a green dot marks the recommended option. **Ammo rules** is
   asked too, inside the Reload mode card, once you pick Manual or Realistic
   reloads. Each choice saves as you pick it, and each setting uses the same
   control here as in Settings. When you run it again from Setup,
   **Fill in the rest with recommended choices** sets only the movement, reload
   and graphics choices you haven't picked on that visit; your hand and seated
   choices never change. Press **Finish setup** (or **Done**).

Feel and fit (snap angle, turn speed, your height, how guns sit in your hands)
are tuned in the headset menu: press the **Menu** button on your left
controller, or press and hold both sticks.

Upgrading from an older release keeps your saved settings and skips both steps.
The Play page says once that settings were reorganized; the old Classic,
Interactive and Advanced reloads show as Button, Manual and Realistic.

The guided VR Training is not part of this release.

## The Play page

- **Game** and **Headset** cards show what KF2-VR will use; click one to open
  **Setup**. **Play in** switches between **VR headset** and **Desktop**.
- **Quick start** (first time) or **Play again** starts your usual session at
  once with the match shown under it: map, difficulty, length and graphics.
- **Solo match**, **Host a game** and **Join a friend** open their forms when you
  want to change the match first.
- A note at the bottom about VAC and XP (see [below](#vac-and-progression)).

Ctrl+Enter presses the page's main button and Esc goes back. Keep the window
open while you play; if you close it, the game keeps going and KF2-VR still puts
Killing Floor 2 back to normal when you quit.

## Playing solo

Click **Solo match**, pick **Map**, **Difficulty** and **Match length**, then
**Start solo match**. In game, choose your perk and press Ready. Solo needs no server
download and no port forwarding. Start with the defaults.

Solo and Host remember their match choices separately. Both start with Burning
Paris, Normal difficulty and Medium length. **Graphics > Change…** on the Solo,
Host and Join pages sets the graphics preset, render scale and DLSS without
leaving the form; your graphics and personal VR settings apply across Solo, Host
and Join.

## Hosting a game (Steam)

1. Click **Host a game**, choose the match, a **Server name** and optionally a
   **Password**, then **Start hosting**. A blank password makes the server open:
   anyone who finds it can join.
2. The first time, KF2-VR downloads the free Killing Floor 2 game server: about
   9 GB to download, 32 GB once installed, so it needs about 35 GB free. The Host page says so before you start.
   It only happens once, and your friends don't need it.
3. When the window says your game is up, click **Copy code** and send the code
   to your friends in a private message. It contains your password.
4. Friends on other internet connections need your router to forward **UDP 7777**
   and **UDP 27015** to your PC. Friends on your home network don't. The Host
   page says so at the top (**How to do it** opens the steps). Allow the Killing
   Floor 2 server through Windows Firewall if asked. Joiners never forward ports.

Under **Players**, **Zed grabs** and **Gravity grab** set what VR players may do
on your server, and **Desktop players can join** lets friends without a headset
get the mod from the Steam Workshop when this version is published there. If it
isn't, hosting still starts and desktop friends need the KF2-VR download. **Mods**
lists the optional mods as switches. The Unofficial KF2 Patch turns on, locked,
while another mod or a Zed spawn change needs it, and the count says how many
mods will load. **Zed spawns** and **Mods** stay folded until you open or change
them. Changing Zed spawns keeps XP on your server; in Solo the form says at once
that the match earns no XP. The map list groups Killing Floor 2's own maps and
Workshop maps.

## Joining a friend (Steam)

Your friend must host with the **same KF2-VR version** you have. Click **Join a
friend**. With **Join with: Join code**, press **Paste** (copy the whole code from
your friend's message first); when it shows the map, press **Join**, then pick
your perk and press Ready. No code? Choose **Address** and enter the host's IP
address or name (add `:port` if their game doesn't use 7777), and the password
if there is one.

## Settings

The launcher and headset show the same three pages, in the same order and
words: **Comfort**, **Hands & Weapons** and **Graphics & HUD**, plus **Audio**.
In headset, open the pause menu's **Settings** entry. **Fun & Cheats** is
separate.

Each page starts with its presets (grip mode, reload mode and ammo rules;
graphics and HUD presets) and the few options people change most. **More
settings** follow as short labelled lists (Hands & Weapons: Grip, Aim & bullet
path, Pickups & Zed grabs and Melee; Reloads with Manual or Realistic reloads).
Settings a preset owns are changed through the preset here and one by one in
the headset; a preset changed there reads **Custom** until you pick an option.
Reload mode: **Button** reloads with X / A; **Manual** reloads by hand, an empty
trigger starts the reload and a new mag drops the old one; **Realistic** also
lets you rack a loaded gun, the empty trigger only clicks and the old mag stays
until you eject it. **Ammo rules** shows with Manual or Realistic. Search also
finds familiar older names. **View controls** explains what each button does
with your settings.

The launcher keeps what you choose before you play. Calibration and fit
(height, hands, gun, pouch, grenade, menu, watch and ammo counter), feel tuning
such as snap angle and haptics, and anything Killing Floor 2's own Options menus
already offer (detail levels, bloom, brightness, gore intensity, volumes, HUD
colors and similar) are set in the headset or the game's menus. Each page ends
with **Elsewhere**: one line each for the headset menu and the game's Options,
with **Show all** for the names. A search for one says where it is.

Valid changes save automatically. While the game runs, launcher settings are
read-only: change them in the headset instead. Settings that don't apply are
hidden; search still finds them and says what turns them on. Each page's
**Reset** and Setup's **Reset all player settings** keep calibration and setup
details.

Fresh installs use Smooth locomotion with a 30-degree snap turn, Mixed grip,
Button reloads, Standard ammo rules, Standard aim assist and HUD preset, and
the Quality graphics preset at 100% render scale. Render scale and DLSS stay
independent of the graphics preset. DLSS starts on Auto: Quality on an
NVIDIA RTX card, ordinary rendering on any other GPU, with 50% sharpening. Gore
is on. Customize graphics & HUD holds bodies, screen effects and the HUD
switches; gore limits and lifetimes are tuned in the headset, and Main grip and
Support grip there too (the launcher sets them through Grip mode).

**Auto-return dropped guns** and **Recall from weapon wheel** are independent
recovery switches. With both Off, retrieve dropped gear by hand or **Gravity
grab**. The wheel has separate **Drop Gun**, **Share Gear** and **Mic Mute**
actions. Sharing starts private each session; picking up shared gear transfers
ownership. The microphone starts muted each session and remembers which active
mode to restore. **Weapon wheel slow-mo** starts On in Solo; it is unavailable
in multiplayer.

**Gravity grab** and **Zed grab and throw** are on by default. Turn them off
for yourself in Hands & Weapons, or for everyone on your server with the Host
page's **Zed grabs** and **Gravity grab** switches.

Existing saved preferences are kept when upgrading. New defaults fill missing
settings; use the reset buttons to adopt all new defaults. **Setup** holds the
game copy, headset check, update notifications and the player-settings reset.
**Help** holds the getting-started steps, your controls,
troubleshooting, recovery, bug-report tools and credits.

## VAC and progression

The Play page says: *KF2-VR plays with VAC (Steam's anti-cheat) off, so it joins only VAC-off servers. Matches earn XP as usual.*

- **VAC is off.** KF2-VR only plays on VAC-off hosts and refuses a host that
  reports VAC enabled. Use Solo or KF2-VR hosted games; don't join VAC-secured
  servers.
- **Progression** saves in ordinary Solo. Updated KF2-VR dedicated hosts enable
  ranked XP automatically, including custom weapon XP; persistence after leaving
  and restarting still needs multiplayer playtest confirmation. Older hosts may
  still disable XP. Practice, Sandbox and cheat actions leave Solo unranked;
  updated dedicated hosts keep ranking enabled for those sessions too.

## Epic Games (experimental Solo VR)

Epic is experimental and has not passed headset acceptance. Host, Join,
Desktop and cross-store online play are unavailable.

1. Start your headset runtime. In **Setup** (or the first-launch step), choose
   **Epic Games**, then click **Play solo**, or **Solo match** and **Start solo match**.
2. Click **Copy launch options**. In Epic, open **Library > Killing Floor 2 >
   Manage > Launch Options**. Save any text already there somewhere safe,
   replace it with the copied line, switch Launch Options on, and click Launch
   in Epic within five minutes. Epic handles sign-in; KF2-VR never reads account
   tokens.
3. At the game's own menu choose **Play Solo Offline**, your map, difficulty and
   length, then your perk and Ready. Keep the KF2-VR window open.
4. After quitting, remove the KF2-VR line from Launch Options and restore your
   previous text and switch setting before normal play.

## Troubleshooting

- **Repair** (Help > Repair after a crash): if KF2 crashed or
  normal KF2 acts strangely, quit KF2 first, then press it. Keep the extracted
  folder until it says Killing Floor 2 is back to normal. With Epic selected it
  runs the Epic recovery.
- **Save logs for a bug report**: asks where to save (the Desktop by default),
  makes a ZIP named `KF2-VR logs <date>.zip` there, opens its folder and copies
  it to the clipboard.
  **Help > Report a bug** opens the KF2-VR thread on the Flat2VR Discord
  (https://discord.com/channels/747967102895390741/1556770175335010444); post it there with your headset, graphics
  card, the version shown in the sidebar, Solo/Host/Join, map, weapon and what
  you were doing.
- **What is anonymized**: personal paths, known usernames and player names,
  account IDs and network addresses are replaced; passwords, recognized tokens
  and join codes are removed. Configs and crash dumps are not included. Original
  logs stay on your PC and nothing is uploaded automatically. Review the ZIP
  before sharing: free-form messages can contain other personal details.
- **Where logs are**: launcher logs in `app\logs` (Help > Logs folder > **Open folder**) and per-session game logs in `app\sessions`. Raw logs, configs and
  crash dumps are not anonymized; keep them private.
- **While a session runs**, the **Session** page shows each step, the join code,
  and errors in plain words. Tick **Show details** for the full log.
- **VR won't start**: check that the headset is connected in its PC app and that
  the app is the active OpenXR runtime. Save logs before changing anything else.
- **Build doesn't match / files missing**: wait for a matching release, or
  extract the complete ZIP into a new folder. Never mix files from different
  releases.

## Updating to a new release

Extract each new release as a **new folder** beside the old one, then open its
**Start KF2-VR.cmd**. Keep the old folder until any stuck session is fixed.
Your settings, your game folder and your host server name and password carry
over automatically: per-PC choices live in `%LOCALAPPDATA%\KF2VR\Profile`, not
in the release folder. The game server (about 32 GB installed) goes in
`KF2-VR Data\KF2VR-Server` at the root of the drive that holds KF2, so every release reuses it. Friends
must all use the same release to play together.
