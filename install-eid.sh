#!/usr/bin/env bash
#
# install-eid.sh — Prijava na eID.gov.rs / eUprava ličnom kartom na Linuxu
#
# Postavlja kompletan lanac za prijavu kvalifikovanim elektronskim
# sertifikatom sa srpske lične karte u Chromium pregledačima (Chrome,
# Brave, Chromium) na Debian/Ubuntu sistemima:
#
#   1. PC/SC servis i CCID drajver za čitač kartica
#   2. srb-id-pkcs11 modul (https://github.com/ubavic/srb-id-pkcs11)
#      izgrađen iz izvora, sa zakrpama za stabilnost u pregledačima
#      (PC/SC transakcije, oporavak ustajale konekcije, osvežavanje
#      liste čitača) — dok zakrpe ne uđu u zvanično izdanje
#   3. Registraciju modula u NSS bazu pregledača (~/.pki/nssdb)
#   4. MUP CA4 lanac sertifikata (posredni + koreni) u NSS bazu
#   5. Opciono: zaobilaženja poznatih konflikata (Realtek kombo čitač,
#      GNOME smartcard servis, OpenSC)
#
# NAPOMENE:
#   - Snap pregledači (snap Brave, snap Firefox bez pcscd interfejsa) NE
#     mogu da pristupe čitaču — koristite .deb verziju pregledača.
#   - Skript ne dira postojeće sertifikate ni privatne podatke.
#
set -euo pipefail

ZIG_VERSION="0.16.0"
SRB_ID_REF="v0.5.0"
PATCH_FILE="$(cd "$(dirname "$0")" && pwd)/srb-id-pkcs11-robustness.patch"
INSTALL_DIR="${HOME}/.local/lib/eid"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mUPOZORENJE:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mGREŠKA:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] && die "Ne pokretati kao root — skript sam traži sudo gde treba."

# ---------------------------------------------------------------- 1. paketi
log "Instaliram sistemske pakete (pcscd, ccid, alati)..."
sudo apt-get update -qq
sudo apt-get install -y -qq pcscd libccid opensc pcsc-tools libnss3-tools \
    git curl xz-utils build-essential
sudo systemctl enable --now pcscd.socket

# ------------------------------------------------------- 2. zig + modul
log "Preuzimam Zig ${ZIG_VERSION}..."
cd "${WORK_DIR}"
curl -fsSL -o zig.tar.xz \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
tar xf zig.tar.xz
ZIG="${WORK_DIR}/zig-x86_64-linux-${ZIG_VERSION}/zig"

log "Preuzimam srb-id-pkcs11 (${SRB_ID_REF})..."
git clone --depth 1 --branch "${SRB_ID_REF}" \
    https://github.com/ubavic/srb-id-pkcs11 "${WORK_DIR}/srb-id-pkcs11"
cd "${WORK_DIR}/srb-id-pkcs11"

if [ -f "${PATCH_FILE}" ]; then
    log "Primenjujem zakrpe za stabilnost..."
    git apply "${PATCH_FILE}" || die "Patch se ne primenjuje — proverite verziju (${SRB_ID_REF})."
else
    warn "Patch fajl nije nađen (${PATCH_FILE}) — gradim NEZAKRPLJEN modul."
    warn "Prijava u pregledaču sa nezakrpljenim modulom često NE radi!"
fi

log "Gradim modul..."
"${ZIG}" build -Doptimize=ReleaseSafe

mkdir -p "${INSTALL_DIR}"
install -m 755 zig-out/lib/libsrb-id-pkcs11.so.* "${INSTALL_DIR}/libsrb-id-pkcs11.so"
log "Modul instaliran: ${INSTALL_DIR}/libsrb-id-pkcs11.so"

# --------------------------------------------------- 3. NSS registracija
log "Registrujem modul u NSS bazu pregledača (~/.pki/nssdb)..."
mkdir -p "${HOME}/.pki/nssdb"
[ -f "${HOME}/.pki/nssdb/pkcs11.txt" ] || certutil -d "sql:${HOME}/.pki/nssdb" -N --empty-password

if pgrep -x brave >/dev/null || pgrep -x chrome >/dev/null || pgrep -x chromium >/dev/null; then
    die "Zatvorite sve pregledače pa pokrenite skript ponovo (NSS baza mora biti slobodna)."
fi

modutil -force -dbdir "sql:${HOME}/.pki/nssdb" -delete "Srb ID PKCS11" >/dev/null 2>&1 || true
modutil -force -dbdir "sql:${HOME}/.pki/nssdb" \
    -add "Srb ID PKCS11" -libfile "${INSTALL_DIR}/libsrb-id-pkcs11.so"

# ----------------------------------------------------- 4. MUP CA4 lanac
log "Uvozim MUP CA4 lanac sertifikata..."
curl -fsSL -o "${WORK_DIR}/MUPGradjaniCA4.crt" http://ca.mup.gov.rs/MUPGradjaniCA4.crt
curl -fsSL -o "${WORK_DIR}/MUPRootCA4.crt"     http://ca.mup.gov.rs/MUPRootCA4.crt
certutil -A -d "sql:${HOME}/.pki/nssdb" -n "MUP Gradjani CA 4" -t ",," -a \
    -i "${WORK_DIR}/MUPGradjaniCA4.crt" 2>/dev/null || true
certutil -A -d "sql:${HOME}/.pki/nssdb" -n "MUP Root CA 4" -t ",," -a \
    -i "${WORK_DIR}/MUPRootCA4.crt" 2>/dev/null || true

# ------------------------------------------ 5. poznati konflikti (opciono)
# 5a. Realtek kombo čitač (smart kartica + SD na istom USB uređaju):
#     kernelovo prozivanje praznog SD slota seče CCID transfere i ubija
#     T=1 protokol. Udev pravilo gasi usb-storage na SD interfejsu.
if lsusb | grep -qi '0bda:0169'; then
    warn "Detektovan Realtek 0bda:0169 kombo čitač — postavljam udev pravilo"
    warn "koje isključuje SD slot tog čitača (smart kartica nije pogođena)."
    sudo tee /etc/udev/rules.d/90-eid-realtek-crw.rules >/dev/null <<'EOF'
# Realtek USB2.0-CRW kombo (smart card + SD): SD interfejs (klasa 08) ometa
# CCID saobracaj ka smart kartici — ne vezuj usb-storage za njega.
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0169", \
  ATTR{bInterfaceClass}=="08", RUN+="/bin/sh -c 'echo -n %k > /sys/bus/usb/drivers/usb-storage/unbind'"
EOF
    sudo udevadm control --reload
    IFACE=$(grep -l '^08$' /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null \
            | xargs -r dirname | xargs -r -n1 basename \
            | while read -r i; do
                v=$(cat "/sys/bus/usb/devices/${i%%:*}/idVendor" 2>/dev/null || true)
                p=$(cat "/sys/bus/usb/devices/${i%%:*}/idProduct" 2>/dev/null || true)
                [ "$v" = 0bda ] && [ "$p" = 0169 ] && echo "$i"
              done)
    if [ -n "${IFACE}" ]; then
        echo -n "${IFACE}" | sudo tee /sys/bus/usb/drivers/usb-storage/unbind >/dev/null 2>&1 || true
    fi
fi

# 5b. GNOME smartcard servis se nadmeće sa pregledačem oko kartice.
if systemctl --user cat org.gnome.SettingsDaemon.Smartcard.service >/dev/null 2>&1; then
    warn "Maskiram GNOME smartcard servis (koristi se za prijavu na računar"
    warn "karticom — ako to koristite, preskočite: systemctl --user unmask ...)"
    systemctl --user mask org.gnome.SettingsDaemon.Smartcard.service 2>/dev/null || true
    pkill -f gsd-smartcard 2>/dev/null || true
fi

# 5c. OpenSC u NSS bazi ne podržava srpske lične karte, a šalje im komande
#     koje se nadmeću sa pravim modulom — ukloni ga ako je registrovan.
modutil -force -dbdir "sql:${HOME}/.pki/nssdb" -list 2>/dev/null \
    | grep -q 'OpenSC' && {
    warn "Uklanjam OpenSC iz NSS baze pregledača (ne podržava LK, pravi konflikt)."
    NAME=$(modutil -dbdir "sql:${HOME}/.pki/nssdb" -list 2>/dev/null \
           | grep -oE 'OpenSC[^"]*framework[^"]*' | head -1)
    [ -n "${NAME}" ] && modutil -force -dbdir "sql:${HOME}/.pki/nssdb" -delete "${NAME}"
} || true

# -------------------------------------------------------------- provera
log "Provera: čitam sertifikate sa kartice kroz modul..."
if timeout 20 pkcs11-tool --module "${INSTALL_DIR}/libsrb-id-pkcs11.so" -O --type cert 2>/dev/null \
        | grep -q 'Certificate'; then
    log "USPEH — kartica i sertifikati su vidljivi!"
else
    warn "Kartica nije očitana. Proverite: da li je kartica u čitaču, da li"
    warn "pcscd radi (systemctl status pcscd), pa pokušajte ponovo."
fi

cat <<'EOF'

────────────────────────────────────────────────────────────────────
GOTOVO. Prijava na https://eid.gov.rs:
  1. Otvorite Chrome/Brave/Chromium (deb verziju, NE snap!)
  2. Prijava kvalifikovanim elektronskim sertifikatom
  3. Izaberite sertifikat sa kartice → unesite PIN
     (PIN može biti zatražen dva puta — to je normalno, dva servera)

Ako nešto ne radi, dijagnostika modula:
  SRB_ID_DEBUG=1 brave-browser 2>debug.log   (statusni kodovi kartice)
────────────────────────────────────────────────────────────────────
EOF
