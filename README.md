<div align="center">

# 👁 HeadSwitch

**Guarda uno schermo, e il focus ci va da solo.**

Una piccola app per la barra dei menu di macOS che usa la webcam per capire quale monitor stai guardando
e porta in primo piano la finestra su quello schermo. Niente click, niente scorciatoie.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

## ✨ Cosa fa

- **Focus che segue lo sguardo**: giri la testa verso un altro monitor e la finestra in primo piano su quello schermo prende il focus.
- **Alone di luce** che esce da sotto la finestra a ogni cambio, così vedi subito dove è andato il focus.
- **Qualsiasi numero di schermi** affiancati in orizzontale: li rileva da solo.
- **Calibrazione guidata** in pochi secondi, con 3 punti per schermo.
- **Leggera**: camera a bassa risoluzione e pochi frame al secondo, spenta quando il Mac va in stop o hai un solo schermo.
- **Privata**: i frame della webcam vengono analizzati in tempo reale e mai salvati né inviati da nessuna parte.
- 100% Swift nativo, con il framework **Vision** di Apple. Niente Python, niente OpenCV.

## 🚀 Installazione

Serve macOS 13 o successivo e gli strumenti di sviluppo di Apple (`xcode-select --install`, oppure Xcode).

```bash
git clone https://github.com/AndreaUnali/HeadSwitch.git
cd HeadSwitch
./scripts/setup_signing.sh   # facoltativo, una volta sola (vedi sotto)
./scripts/build_app.sh       # compila, installa in /Applications e avvia
```

Al primo avvio:

1. Consenti l'accesso alla **webcam**.
2. Attiva HeadSwitch in **Impostazioni di Sistema → Privacy e sicurezza → Accessibilità** (serve per portare in primo piano le finestre).
3. Segui la **calibrazione**: su ogni schermo compaiono 3 punti (sinistra, centro, destra). Gira la testa verso il punto e tienila ferma finché l'anello si completa.

Fatto. Guarda l'altro schermo e il focus ti segue.

### 🔄 Aggiornamento

```bash
./scripts/update.sh
```

Scarica le novità, ricompila e riavvia l'app.

> **Perché `setup_signing.sh`?** Crea un certificato di firma locale. Senza, macOS considera ogni build
> un'app diversa e ti chiede di riattivare l'Accessibilità a ogni aggiornamento.

## 🎛 Menu

Clicca sull'icona 👁 nella barra dei menu:

| Voce | Cosa fa |
|---|---|
| Cambia focus con lo sguardo | Attiva o disattiva il controllo |
| Ricalibra schermi… | Rifà la calibrazione (da fare se cambi sedia, posizione o monitor) |
| Reattività | Quanto devi restare a guardare uno schermo prima del cambio: Veloce, Normale, Calma |
| Luce di contorno | Attiva o disattiva l'alone sulla finestra |
| Mostra angolo nella barra | Mostra accanto all'icona l'angolo della testa e lo schermo rilevato (es. `+12° → 2`) |
| Apri al login | Avvia HeadSwitch all'accensione del Mac |

## 🧠 Come funziona

```
Webcam ─▶ Vision (yaw del viso) ─▶ zona dello schermo ─▶ finestra in primo piano ─▶ alone di luce
```

1. **`CameraManager`** cattura video a 640×480 e 12 fps.
2. **`VisionProcessor`** legge l'angolo di rotazione orizzontale (*yaw*) del viso con `VNDetectFaceRectanglesRequest`.
3. **`GazeZoneDetector`** lo leviga con una media mobile esponenziale e lo confronta con i confini calibrati tra gli schermi.
   Per cambiare zona devi superare il confine di un margine e restarci per almeno ~400 ms, così uno sguardo distratto non fa scattare nulla.
4. **`WindowManager`** trova la finestra più in alto su quello schermo (`CGWindowList`) e la porta in primo piano con le API di Accessibilità.
5. **`FocusGlow`** disegna l'alone di luce dietro la finestra.

## ⚠️ Limiti noti

- Funziona sulla **rotazione orizzontale della testa**, non sulla direzione degli occhi: per guardare un altro schermo devi girare un po' la testa.
- Schermi disposti **uno sopra l'altro** non sono ancora distinguibili.
- Se giri la testa così tanto che Vision perde il volto, il focus resta dov'è.
- Con la luce molto scarsa la rilevazione peggiora.

## 🛠 Risoluzione problemi

- **Non succede nulla**: controlla che Webcam e Accessibilità siano attivi per HeadSwitch. Per ripartire da zero:
  `tccutil reset Accessibility dev.headswitch.app` e `tccutil reset Camera dev.headswitch.app`.
- **Cambia schermo al momento sbagliato**: attiva *Mostra angolo nella barra*, guarda i due schermi e controlla che i numeri siano ben distinti; poi *Ricalibra schermi…*.
- **`codesign` si lamenta di "resource fork"**: la cartella è su Desktop o Documenti sincronizzati con iCloud. Lo script ripulisce già gli attributi; in alternativa clona la repo fuori da iCloud.

## 🤝 Contribuire

Issue e pull request sono benvenute. Il codice è piccolo (una decina di file in `Sources/HeadSwitch`) e la logica di rilevamento
è isolata in `GazeZoneDetector.swift`, che non dipende da nessun framework di sistema.

## 📄 Licenza

[MIT](LICENSE)
