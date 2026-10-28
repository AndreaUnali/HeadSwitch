# HeadSwitch

Come Glance Switch: con due o più monitor affiancati, **guardi uno schermo e il focus passa alla finestra
in primo piano su quello schermo**, con un breve alone di luce che esce da sotto la finestra.

## Installazione / aggiornamento
```bash
git clone https://github.com/<tuo-utente>/HeadSwitch.git && cd HeadSwitch
./scripts/setup_signing.sh   # facoltativo, una volta: firma stabile (l'Accessibilità non si resetta a ogni update)
./scripts/build_app.sh       # compila, installa in /Applications, avvia
```
Per aggiornare: `./scripts/update.sh` (git pull + ricompila + riavvia).

Al primo avvio concedi **Webcam** e **Accessibilità**, poi la calibrazione guidata: su ogni schermo 3 punti
(sinistra, centro, destra). Gira la testa verso il punto e tienila ferma finché l'anello si completa.

## Note
- Il numero di schermi è rilevato in automatico, purché siano affiancati in orizzontale.
- Menu 👁: attiva/disattiva, ricalibra, reattività, luce di contorno, angolo live nella barra, apri al login.
- "Mostra angolo nella barra": accanto all'icona compare lo yaw e lo schermo rilevato (es. `+12° → 2`), utile per capire se la calibrazione è buona.

## Architettura
`CameraManager` → `VisionProcessor` (yaw) → `GazeZoneDetector` (confini tra schermi + isteresi + dwell)
→ `WindowManager` (CGWindowList + Accessibilità) → `FocusGlow` (alone dietro la finestra).
