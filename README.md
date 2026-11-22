# Battleships (Wi-Fi) for KOReader

The classic Battleships game for two players, each on their own e-reader, over Wi-Fi, or for one player against the e-reader. English, with a Czech translation (Lodě). Installs as `battleshipswifi` (until 0.2.0 `battleships`: uninstall that one, the name you set is taken over).

## Playing
In the menu: **Tools → Battleships (Wi-Fi)**. For two players, both devices must be on the same Wi-Fi network.

- **Host a game**: one player picks the fleet (**Classic ships** or **Shaped ships**), opens a game and places their ships right away. The screen shows the device's address.
- **Find a game**: the other player sees games open on the local network (UDP broadcast), with their fleet, and taps one to join.
- **Join by address…**: when the search finds nothing (some networks block broadcasts), type the address shown on the host's screen, e.g. `192.168.1.10` (or `192.168.1.10:7531`).
- **Play against the e-reader**: one player, no network. Pick the fleet; **Difficulty** sets how the e-reader plays:
  - **Easy**: random shots, and after a hit it fires next to it only half of the time (about 63 shots to sink the classic fleet).
  - **Normal**: hunts on a checkerboard and finishes off what it hit, along the line of hits (about 43).
  - **Hard**: for every square, counts the ways the ships still afloat could lie over it, given the misses, the sunk ships and that ships don't touch, and fires at the likeliest one (about 38).

  Going to sleep doesn't end this game.
- **Keys** (for readers without touch, or one hand): the arrows move a cursor on the board (it shows once a key is pressed), **Press** acts on its square like a tap (fires; while placing: picks up, turns, puts down a ship), the page keys step through the squares (in the battle, to the next one not fired at yet). Without arrows, page back steps to the next square and page forward acts. **Menu** shows the screen's buttons (Ready, Random, Mirror, Play again, Close) in a dialog that works with keys.
- **Your name**: shown to the other player and in the list of games (default: the device model).
- **Animations** (on by default), on both boards: a miss is a shell, a splash, a water column and spreading ripples (about 0.9 s); a hit is a shell, a flash, a fireball, flying debris and smoke over the fire (0.75 s); a sunk ship blows up square by square, then all at once, breaks up and goes down under the waves (up to about 1 s). Each frame is a fast refresh of the squares and their neighbours; turn them off on slow screens.

### Rules
- The host picks the fleet, on a 10 × 10 board:
  - **Classic ships**: five straight ships of 5, 4, 3, 3 and 2 squares (17 squares).
  - **Shaped ships**: six ships, 24 squares (`#` = ship):

    ```
    aircraft carrier  cruiser  battleship  destroyer  2 submarines
    ####              .#.      ####        #..        ##
    .##.              ###      .#..        ###
                      .#.
    ```
- Ships may not touch, not even at the corners.
- Rules picked before starting (in **Host a game** and **Play against the e-reader**, they stay for the next games): **Board 12 × 12**, **Salvo** (each turn as many shots as you have ships afloat; a hit doesn't give another shot, the status line counts the shots left) and **Ships may touch** (then the water around a sunk ship isn't marked). The list of games shows them.
- Placing: the fleet starts at random positions (**Random** shuffles it again). **Drag a ship** with your finger to move it: while dragging, the board shows where it would land (dark: it fits; hollow squares: no room; its old place light); lifting the finger off the board cancels. Or tap a ship to select it, tap it again to turn it (a quarter turn clockwise, or the next one that fits), tap the water to move it there (the leftmost square of its top row lands on the square tapped). While a ship is selected, the squares it doesn't fit on are shaded, and the status line says when it has no room to turn. With shaped ships, **Mirror** flips the selected ship (an L becomes a J, the battleship's foot goes to the other side). **Ready** when done.
- The host's device picks who fires first. After a hit you fire again; after a miss it's the opponent's turn.
- Water around a sunk ship is marked automatically. Whoever sinks the whole enemy fleet first wins; the loser then sees the winner's remaining ships. **Play again** starts a new round once both players tap it.
- A sunk ship is named in the message (aircraft carrier, battleship, cruiser, destroyer, submarine; the classic fleet's two ships of 3 are both cruisers). After each game, both players' numbers: shots, hits, hit rate and the longest series of hits. The title shows the score of the games played against the same opponent (Play again keeps it).

Board marks: gray ship = yours (dark gray = selected), light gray = no room for the selected ship, dot in a ring = miss, flame = hit, black ship = sunk, light dot = water next to a sunk ship. The last shot is outlined. Below the opponent's board, their fleet in small: ships still afloat dark, sunk ones light and struck through.

## Network
- TCP 7531 (the game, host), UDP 7532 (host answers searches), UDP 7533 (searching device listens for answers).
- On Kindle the plugin opens these ports in the firewall (iptables) for the time of the game.
- The device doesn't go to standby during a game.
- Once the battle has started, a lost connection doesn't end the game (both devices need 0.7.0 or newer): the host waits for its opponent to come back, the other device keeps reconnecting (every 3 s; if the host's address changed, it finds it by searching the network). Going to sleep works the same way: on waking up the game goes on where it was, shots sent while the connection was down included. **Close** gives up. Before the battle, or with an older version, a lost connection ends the game as before.
- Closing or restarting KOReader (or a crash) doesn't lose such a game, nor a game against the e-reader: it is saved after every move (`settings/battleshipswifi_game.lua`), and the menu then starts with **Continue the game against …**. A network game then waits for the other device as after a lost connection (the other device must still be in the game). Starting another game, or closing this one, drops what was saved.

## Development
Protocol version 4 since 1.1.0 (rules: board size, salvo, touching ships): versions before it can't play with it; version 3 came with 1.0.0 (mirrored ships), 2 with 0.3.0 (fleets, shaped ships).

Off-device tests (`lua5.1` works too when luajit isn't installed):

```bash
luajit tests/run.lua
```

```bash
luajit tests/smoke.lua
```

## License

This plugin is free software: you can redistribute it and/or modify it under the
terms of the GNU Affero General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later version,
like KOReader itself. See [LICENSE](LICENSE).
