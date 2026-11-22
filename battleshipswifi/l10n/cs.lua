-- Czech translation of the plugin's strings (msgid → translation), see battleshipswifi/l10n.lua.
-- tests/run.lua checks that every _("…") in main.lua has an entry here.
return {
    -- menu
    ["Battleships"] = "Lodě",
    ["Battleships (Wi-Fi)"] = "Lodě",
    ["Host a game"] = "Založit hru",
    ["Find a game"] = "Najít hru",
    ["Join by address…"] = "Připojit se podle adresy…",
    ["Your name: %1"] = "Vaše jméno: %1",
    ["Your name"] = "Vaše jméno",
    ["Shown to the other player and in the list of games."] = "Zobrazí se druhému hráči a v seznamu her.",
    ["Player"] = "Hráč",
    ["Save"] = "Uložit",
    ["Rules"] = "Pravidla",
    ["Animations"] = "Animace",
    ["Settings"] = "Nastavení",
    ["Play against the e-reader"] = "Hrát proti čtečce",
    ["Difficulty: %1"] = "Obtížnost: %1",
    ["Easy"] = "Lehká",
    ["Normal"] = "Střední",
    ["Hard"] = "Těžká",
    ["E-reader"] = "Čtečka",
    ["You play against the e-reader. Difficulty: %1."] = "Hrajete proti čtečce. Obtížnost: %1.",
    ["Classic ships"] = "Klasické lodě",
    ["Shaped ships"] = "Tvarové lodě",
    ["Start game"] = "Spustit hru",
    ["Ships: %1"] = "Lodě: %1",
    ["%1 (%2)"] = "%1 (%2)",
    ["You joined %1's game: %2."] = "Připojeno ke hře hráče %1: %2.",
    ["%1 × %1"] = "%1 × %1",
    ["salvo"] = "salvy",
    ["ships may touch"] = "lodě se smějí dotýkat",
    ["Board: %1 × %1"] = "Plán: %1 × %1",
    ["Salvo (a shot per ship afloat)"] = "Salvy (výstřel za každou loď)",
    ["Ships may touch"] = "Lodě se smějí dotýkat",
    ["%1: hit!"] = "%1: zásah!",
    ["%1 · %2"] = "%1 · %2",
    ["Your turn."] = "Jste na tahu.",
    ["Your turn: %1 shots left."] = "Jste na tahu: zbývá výstřelů %1.",
    ["Your turn: tap a square on the opponent's board. Shots left: %1."] = "Jste na tahu: klepněte na pole soupeřova plánu. Zbývá výstřelů: %1.",
    [ [[The host picks the fleet. Classic ships: five straight ships of 5, 4, 3, 3 and 2 squares. Shaped ships: an aircraft carrier (a row of 4 with 2 below the middle), a cruiser (a cross of 5), a battleship (a row of 4 with 1 below), a destroyer (an L of 4) and two submarines of 2. Ships lie on a 10 × 10 board and may not touch, not even at the corners.

Players take turns firing at a square of the opponent's board. After a hit you fire again, after a miss it's the opponent's turn. Whoever sinks the whole enemy fleet first wins.

Two players: both devices must be on the same Wi-Fi network. One player hosts the game, the other finds it in Find a game or joins by the address shown on the host's screen.

One player: Play against the e-reader, on one device and without a network. The e-reader plays easy, normal or hard (Difficulty).

Rules to pick before starting (Host a game, Play against the e-reader): a 12 × 12 board, salvo (each turn as many shots as you have ships afloat, a hit doesn't give another one) and ships that may touch (then the water around a sunk ship isn't marked).

With keys: the arrows (or the page keys) move a cursor on the board, Press fires or picks up, turns and puts down a ship; without arrows, page back steps to the next square and page forward fires. Menu shows the screen's buttons.]] ] =
        [[Flotilu vybírá zakládající hráč. Klasické lodě: pět rovných lodí o 5, 4, 3, 3 a 2 polích. Tvarové lodě: letadlová loď (řada 4 polí a pod jejím středem 2), křižník (kříž z 5 polí), bitevní loď (řada 4 polí a pod ní 1), torpédoborec (L ze 4 polí) a dvě ponorky po 2 polích. Lodě leží na plánu 10 × 10 a nesmějí se dotýkat, ani rohem.

Hráči se střídají ve střelbě na pole soupeřova plánu. Po zásahu střílíte znovu, po minutí je na tahu soupeř. Kdo první potopí celou nepřátelskou flotilu, vyhrává.

Dva hráči: obě zařízení musí být ve stejné síti Wi-Fi. Jeden hráč hru založí, druhý ji najde v Najít hru nebo se připojí podle adresy zobrazené na obrazovce zakládajícího hráče.

Jeden hráč: Hrát proti čtečce, na jednom zařízení a bez sítě. Čtečka hraje lehce, středně nebo těžce (Obtížnost).

Pravidla se volí před začátkem (Založit hru, Hrát proti čtečce): plán 12 × 12, salvy (za tah tolik výstřelů, kolik vám pluje lodí, zásah další výstřel nedává) a lodě, které se smějí dotýkat (pak se voda kolem potopené lodi neoznačuje).

Klávesami: šipky (nebo tlačítka pro otáčení stránek) posouvají kurzor po plánu, Press vystřelí nebo loď vybere, otočí a položí; bez šipek posune tlačítko zpět kurzor na další pole a tlačítko vpřed vystřelí. Menu ukáže tlačítka obrazovky.]],

    -- joining
    ["Join by address"] = "Připojit se podle adresy",
    ["The address is shown on the host's screen."] = "Adresa je zobrazena na obrazovce zakládajícího hráče.",
    ["Cancel"] = "Zrušit",
    ["Join"] = "Připojit",
    ["Invalid address"] = "Neplatná adresa",
    ["Searching for games…"] = "Hledání her…",
    ["Cannot search for games: %1"] = "Hry nelze hledat: %1",
    ["Cannot host a game: %1"] = "Hru nelze založit: %1",
    ["Connecting to %1…"] = "Připojování k %1…",
    ["Cannot connect to %1: %2"] = "Nelze se připojit k %1: %2",
    ["Connecting…"] = "Připojování…",

    -- game screen
    ["Opponent: %1"] = "Soupeř: %1",
    ["Place your ships: drag them, or tap a ship to select it, tap it again to turn it, tap the water to move it there."] =
        "Rozmístěte lodě: přetáhněte je prstem, nebo klepnutím loď vyberete, dalším klepnutím ji otočíte, klepnutím na vodu ji tam přesunete.",
    ["Mirror"] = "Zrcadlit",
    ["The ship cannot be mirrored here."] = "Loď tady nejde zrcadlit.",
    ["Tap the water to move the ship, tap the ship to turn it. Shaded squares have no room for it."] =
        "Klepnutím na vodu loď přesunete, klepnutím na loď ji otočíte. Na světle šedá pole se loď nevejde.",
    ["Tap the water to move the ship. Shaded squares have no room for it, and it has no room to turn here."] =
        "Klepnutím na vodu loď přesunete. Na světle šedá pole se loď nevejde a tady ji nelze otočit.",
    ["Waiting for %1 to place their ships…"] = "Čeká se, až %1 rozmístí lodě…",
    ["Waiting for an opponent. Your address: %1"] = "Čeká se na soupeře. Vaše adresa: %1",
    ["Waiting for an opponent."] = "Čeká se na soupeře.",
    ["Firing…"] = "Pálí se…",
    ["Your turn: tap a square on the opponent's board."] = "Jste na tahu: klepněte na pole soupeřova plánu.",
    ["%1 is aiming…"] = "%1 míří…",
    ["You won!"] = "Vyhráli jste!",
    ["%1 won."] = "Vyhrává %1.",
    ["Waiting for %1…"] = "Čeká se na %1…",
    ["%1 wants to play again."] = "%1 chce hrát znovu.",
    ["Close"] = "Zavřít",
    ["Random"] = "Náhodně",
    ["Ready"] = "Hotovo",
    ["Play again"] = "Hrát znovu",
    ["The ship cannot turn here."] = "Loď tady nejde otočit.",
    ["The ship does not fit there. Ships may not touch."] = "Loď se tam nevejde. Lodě se nesmějí dotýkat.",
    ["Leave the game?"] = "Opustit hru?",
    ["Leave"] = "Odejít",

    -- game events
    ["The other device has a different version of Battleships."] = "Druhé zařízení má jinou verzi hry Lodě.",
    ["This game already has two players."] = "Tato hra už má dva hráče.",
    ["The opponent"] = "Soupeř",
    ["%1 left."] = "%1 odchází.",
    ["%1 left the game."] = "%1 opouští hru.",
    ["Connection to %1 lost."] = "Spojení se soupeřem %1 bylo přerušeno.",
    ["Connection to %1 restored."] = "Spojení se soupeřem %1 je obnoveno.",
    ["Waiting for %1 to come back…"] = "Čeká se, až se %1 znovu připojí…",
    ["Reconnecting to %1…"] = "Znovu se připojuje k soupeři %1…",
    ["The game can no longer be resumed."] = "Hru už nelze obnovit.",
    ["Continue the game against %1"] = "Pokračovat ve hře proti: %1",
    ["Continuing the game against %1."] = "Pokračuje hra proti: %1.",
    ["The saved game cannot be continued."] = "V uložené hře nelze pokračovat.",
    ["Connection lost."] = "Spojení bylo přerušeno.",
    ["%1: miss."] = "%1: vedle.",
    ["%1: hit! Fire again."] = "%1: zásah! Střílejte znovu.",
    ["%1: hit, the %2 goes down! Fire again."] = "%1: zásah, %2 jde ke dnu! Střílejte znovu.",
    ["%1: hit, the %2 goes down!"] = "%1: zásah, %2 jde ke dnu!",
    ["%1 fired at %2: miss."] = "%1 střílí na %2: vedle.",
    ["%1 fired at %2: hit."] = "%1 střílí na %2: zásah.",
    ["%1 fired at %2: your %3 goes down."] = "%1 střílí na %2: %3 jde ke dnu.",
    ["%1 fired at %2: your %3 goes down, your last ship."] = "%1 střílí na %2: ke dnu jde %3, vaše poslední loď.",
    ["aircraft carrier"] = "letadlová loď",
    ["battleship"] = "bitevní loď",
    ["cruiser"] = "křižník",
    ["destroyer"] = "torpédoborec",
    ["submarine"] = "ponorka",
    ["ship"] = "loď",
    ["Opponent: %1 · You %2 : %3"] = "Soupeř: %1 · Vy %2 : %3",
    ["You: %1 of %2 shots hit (%3 %), longest series %4."] = "Vy: zásah %1 z %2 výstřelů (%3 %), nejdelší série %4.",
    ["%1: %2 of %3 shots hit (%4 %), longest series %5."] = "%1: zásah %2 z %3 výstřelů (%4 %), nejdelší série %5.",
    ["%1 joined the game."] = "Do hry vstupuje %1.",
    ["%1 is ready."] = "%1: připraveno.",
    ["The battle begins. You fire first."] = "Bitva začíná. Střílíte první.",
    ["The battle begins. %1 fires first."] = "Bitva začíná. Jako první střílí %1.",
    ["New game: place your ships."] = "Nová hra: rozmístěte lodě.",
}
