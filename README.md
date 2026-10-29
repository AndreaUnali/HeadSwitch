<div align="center">

# 👁 HeadSwitch

**Guarda uno schermo, e il focus ci va da solo.**

Una piccola app per la barra dei menu di macOS che usa la webcam per capire quale monitor (e, se vuoi, quale finestra)
stai guardando e le dà il focus. Niente click, niente scorciatoie.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

## ✨ Cosa fa

- **Focus che segue lo sguardo**: giri la testa verso un altro monitor e la finestra in primo piano su quello schermo prende il focus.
- **Selezione per finestra (beta)**: oltre allo schermo, sceglie anche la finestra che stai guardando *dentro* lo stesso schermo.
- **Qualsiasi disposizione di schermi**: affiancati, uno sopra l'altro o in diagonale. Il numero di schermi è rilevato da solo.
- **Calibrazione guidata** a 5 o 9 punti per schermo, che misura la posizione reale dei tuoi monitor sulla scrivania.
- **Alone di luce** che esce da sotto la finestra a ogni cambio, così vedi subito dove è andato il focus.
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
3. Segui la **calibrazione**: su ogni schermo compaiono dei punti (5 o 9). Gira la testa verso il punto e tienila ferma finché l'anello si completa.

Fatto. Guarda l'altro schermo e il focus ti segue.

### 🔄 Aggiornamento

```bash
./scripts/update.sh
```

Scarica le novità, ricompila e riavvia l'app. Se cambia il formato della calibrazione, l'app te la richiede da sola.

> **Perché `setup_signing.sh`?** Crea un certificato di firma locale. Senza, macOS considera ogni build
> un'app diversa e ti chiede di riattivare l'Accessibilità a ogni aggiornamento.

## 🎛 Menu

Clicca sull'icona 👁 nella barra dei menu:

| Voce | Cosa fa |
|---|---|
| Cambia focus con lo sguardo | Attiva o disattiva il controllo |
| Ricalibra schermi… | Rifà la calibrazione (da fare se cambi sedia, posizione o monitor) |
| Punti di calibrazione | 5 punti (veloce) o 9 punti (preciso). Dopo averlo cambiato, ricalibra |
| Reattività | Quanto devi restare a guardare uno schermo o una finestra prima del cambio: Veloce, Normale, Calma |
| Selezione per finestra (beta) | Sceglie anche la finestra guardata dentro lo schermo |
| Luce di contorno | Attiva o disattiva l'alone sulla finestra |
| Mostra angolo nella barra | Mostra accanto all'icona yaw, pitch e schermo rilevato (es. `+12° -4° → 2`) |
| Apri al login | Avvia HeadSwitch all'accensione del Mac |

Dopo la calibrazione la riga di stato mostra l'**errore medio** del modello (es. `errore ~1.8°`): più è basso, meglio l'app capisce dove guardi.

## 🧠 Come funziona

```
Webcam ─▶ Vision (yaw + pitch del viso) ─▶ modello per schermo ─▶ schermo / finestra guardati ─▶ focus + alone di luce
```

1. **`CameraManager`** cattura video a 640×480 e 12 fps.
2. **`VisionProcessor`** legge yaw (rotazione orizzontale) e pitch (inclinazione verticale) del viso con `VNDetectFaceRectanglesRequest`.
3. **`GazeZoneDetector`** leviga la posa con una media mobile esponenziale. Durante la calibrazione ricava per ogni schermo
   un modello ai minimi quadrati tra i punti guardati e la posa misurata, poi sceglie lo schermo la cui regione è più vicina alla posa attuale.
   Per cambiare servono un margine di isteresi e almeno ~400 ms di permanenza, così uno sguardo distratto non fa scattare nulla.
   Se guardi altrove (tastiera, telefono) non succede niente.
4. **`WindowManager`** trova la finestra giusta (`CGWindowList`) e la porta in primo piano con le API di Accessibilità.
5. **`FocusGlow`** disegna l'alone di luce dietro la finestra.

Con la **selezione per finestra** l'app usa lo stesso modello per stimare il punto esatto guardato sullo schermo e dà il focus alla finestra
che ci sta sotto. Se stai scrivendo (un tasto premuto negli ultimi ~0,8 s) il cambio di finestra aspetta, per non farti finire a digitare altrove.

## ⚠️ Limiti noti

- Funziona sulla **posa della testa**, non sulla direzione degli occhi: per guardare un altro schermo devi girare un po' la testa.
- La precisione dentro uno schermo è di qualche centimetro: la selezione per finestra va bene per finestre affiancate o in colonna
  di almeno ~10 cm, non per finestre piccole o sovrapposte.
- Se due schermi producono pose troppo simili (angoli quasi uguali) la calibrazione fallisce: gira di più la testa verso ogni punto.
- Se giri la testa così tanto che Vision perde il volto, il focus resta dov'è.
- Con la luce molto scarsa la rilevazione peggiora.
- La webcam resta accesa finché il controllo è attivo, quindi l'indicatore di sistema resta visibile: è una protezione di macOS e non si può nascondere.

## 🛠 Risoluzione problemi

- **Non succede nulla**: controlla che Webcam e Accessibilità siano attivi per HeadSwitch. Per ripartire da zero:
  `tccutil reset Accessibility dev.headswitch.app` e `tccutil reset Camera dev.headswitch.app`.
- **Cambia schermo al momento sbagliato**: attiva *Mostra angolo nella barra*, guarda i vari schermi e controlla che il numero dopo la freccia sia quello giusto;
  poi *Ricalibra schermi…*, magari con 9 punti.
- **Errore di calibrazione alto**: rifai la calibrazione tenendo la testa davvero ferma su ogni punto e con il volto ben illuminato.
- **`codesign` si lamenta di "resource fork"**: la cartella è su Desktop o Documenti sincronizzati con iCloud. Lo script ripulisce già gli attributi; in alternativa clona la repo fuori da iCloud.

## 🤝 Contribuire

Issue e pull request sono benvenute. Il codice è piccolo (una dozzina di file in `Sources/HeadSwitch`) e la logica di rilevamento
è isolata in `GazeZoneDetector.swift`, che non dipende da nessun framework di sistema.

## 📄 Licenza

[MIT](LICENSE)
