#!/usr/bin/env bash
# Facoltativo, da fare una sola volta: crea un certificato di firma locale "HeadSwitch Dev".
# Con una firma stabile macOS ricorda il permesso di Accessibilità anche dopo ogni update.
# Può chiedere la password del Mac (per fidarsi del certificato) e, alla prima build, il permesso di usare la chiave.
set -euo pipefail
NAME="HeadSwitch Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Certificato \"$NAME\" già presente."; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null \
 && /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:headswitch \
 && security import "$TMP/id.p12" -k "$KEYCHAIN" -P headswitch -T /usr/bin/codesign \
 && security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  echo "Certificato creato. Le prossime build lo useranno automaticamente."
else
  cat <<MSG
Non sono riuscito a creare il certificato in automatico. Fallo a mano (1 minuto):
  Accesso Portachiavi → menu Accesso Portachiavi → Assistente Certificati → Crea un certificato…
  Nome: $NAME · Tipo di identità: Radice autofirmata · Tipo di certificato: Firma codice → Crea.
MSG
  exit 1
fi
