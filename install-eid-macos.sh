#!/usr/bin/env bash
#
# install-eid-macos.sh — Prijava na eID.gov.rs / eUprava ličnom kartom na macOS-u
#
# macOS varijanta install-eid.sh skripta. Ključne razlike u odnosu na Linux:
#
#   - Chromium pregledači (Chrome, Brave) na macOS-u koriste Keychain /
#     CryptoTokenKit i NE mogu da učitaju PKCS#11 modul — prijava radi
#     SAMO iz Firefox-a.
#   - PC/SC servis i CCID drajver su ugrađeni u macOS: pcscd, udev pravila
#     i ostala Linux zaobilaženja ne trebaju (ni SD slot Realtek 0bda:0169
#     kombo čitača ne smeta).
#   - Modul i MUP CA sertifikati se registruju kroz Firefox enterprise
#     policies.json (u samom app bundle-u), ne kroz ~/.pki/nssdb.
#
# NAPOMENA: Firefox update briše policies.json iz app bundle-a! Skript zato
# ostavlja kopiju u ~/.local/lib/eid/ — ako prijava prestane da radi posle
# update-a, samo je vratite:
#   cp ~/.local/lib/eid/policies.json "/Applications/Firefox.app/Contents/Resources/distribution/"
#
set -euo pipefail

ZIG_VERSION="0.16.0"
SRB_ID_REF="v0.5.0"
PATCH_FILE="$(cd "$(dirname "$0")" && pwd)/srb-id-pkcs11-robustness.patch"
INSTALL_DIR="${HOME}/.local/lib/eid"
FIREFOX_APP="/Applications/Firefox.app"
DIST_DIR="${FIREFOX_APP}/Contents/Resources/distribution"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mUPOZORENJE:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mGREŠKA:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Ovaj skript je za macOS — na Linuxu koristite install-eid.sh."
[ "$(id -u)" = 0 ] && die "Ne pokretati kao root."

case "$(uname -m)" in
    arm64)  ZIG_ARCH="aarch64" ;;
    x86_64) ZIG_ARCH="x86_64" ;;
    *) die "Nepoznata arhitektura: $(uname -m)" ;;
esac

# ------------------------------------------------------------- 1. Firefox
if [ ! -d "${FIREFOX_APP}" ]; then
    if command -v brew >/dev/null; then
        log "Instaliram Firefox (brew cask)..."
        brew install --cask firefox
    else
        die "Firefox nije instaliran — preuzmite ga sa https://www.mozilla.org/firefox/ pa pokrenite skript ponovo."
    fi
fi
# Gatekeeper ume prvi start sveže preuzetog Firefox-a da dočeka dijalogom
# (i klik na "Move to Trash" ga nosi u korpu) — skini quarantine unapred.
xattr -dr com.apple.quarantine "${FIREFOX_APP}" 2>/dev/null || true

if pgrep -xq firefox; then
    warn "Firefox je pokrenut — politike se učitavaju tek pri sledećem startu."
    warn "Restartujte ga kad skript završi."
fi

# ------------------------------------------------------- 2. zig + modul
log "Preuzimam Zig ${ZIG_VERSION} (${ZIG_ARCH})..."
cd "${WORK_DIR}"
curl -fsSL -o zig.tar.xz \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-macos-${ZIG_VERSION}.tar.xz"
tar xf zig.tar.xz
ZIG="${WORK_DIR}/zig-${ZIG_ARCH}-macos-${ZIG_VERSION}/zig"

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

log "Gradim modul (build.zig već podržava macOS / PCSC.framework)..."
"${ZIG}" build -Doptimize=ReleaseSafe

mkdir -p "${INSTALL_DIR}"
install -m 755 "zig-out/lib/libsrb-id-pkcs11.${SRB_ID_REF#v}.dylib" \
    "${INSTALL_DIR}/libsrb-id-pkcs11.dylib"
log "Modul instaliran: ${INSTALL_DIR}/libsrb-id-pkcs11.dylib"

# ----------------------------------------------------- 3. MUP CA4 lanac
log "Preuzimam MUP CA4 lanac sertifikata..."
curl -fsSL -o "${INSTALL_DIR}/MUPGradjaniCA4.crt" http://ca.mup.gov.rs/MUPGradjaniCA4.crt
curl -fsSL -o "${INSTALL_DIR}/MUPRootCA4.crt"     http://ca.mup.gov.rs/MUPRootCA4.crt

# ------------------------------------- 4. Firefox policies.json registracija
log "Registrujem modul i sertifikate kroz Firefox policies.json..."
mkdir -p "${DIST_DIR}"
cat > "${DIST_DIR}/policies.json" <<EOF
{
  "policies": {
    "SecurityDevices": {
      "Add": {
        "Srb ID PKCS11": "${INSTALL_DIR}/libsrb-id-pkcs11.dylib"
      }
    },
    "Certificates": {
      "Install": [
        "${INSTALL_DIR}/MUPGradjaniCA4.crt",
        "${INSTALL_DIR}/MUPRootCA4.crt"
      ]
    }
  }
}
EOF
# kopija van bundle-a — Firefox update briše distribution/ direktorijum
cp "${DIST_DIR}/policies.json" "${INSTALL_DIR}/policies.json"

# -------------------------------------------------------------- provera
# Na macOS-u nema pkcs11-tool — mali C test učitava modul i lista tokene.
log "Provera: čitam token sa kartice kroz modul..."
if command -v cc >/dev/null; then
    cat > "${WORK_DIR}/p11test.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
typedef unsigned long CK_RV, CK_ULONG, CK_SLOT_ID;
typedef struct { unsigned char major, minor; } CK_VERSION;
typedef struct { unsigned char label[32], man[32], model[16], ser[16];
                 CK_ULONG flags; unsigned char rest[256]; } CK_TOKEN_INFO;
typedef struct {
    CK_VERSION version;
    CK_RV (*C_Initialize)(void *);
    CK_RV (*C_Finalize)(void *);
    CK_RV (*C_GetInfo)(void *);
    CK_RV (*C_GetFunctionList)(void *);
    CK_RV (*C_GetSlotList)(unsigned char, CK_SLOT_ID *, CK_ULONG *);
    CK_RV (*C_GetSlotInfo)(void *, void *);
    CK_RV (*C_GetTokenInfo)(CK_SLOT_ID, CK_TOKEN_INFO *);
} FL;
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    CK_RV (*getfl)(FL **) = (CK_RV (*)(FL **))dlsym(h, "C_GetFunctionList");
    FL *fl = NULL;
    if (!getfl || getfl(&fl) || !fl) { printf("C_GetFunctionList FAIL\n"); return 1; }
    if (fl->C_Initialize(NULL)) { printf("C_Initialize FAIL\n"); return 1; }
    CK_SLOT_ID slots[16]; CK_ULONG n = 16;
    if (fl->C_GetSlotList(1, slots, &n)) { printf("C_GetSlotList FAIL\n"); return 1; }
    for (CK_ULONG i = 0; i < n; i++) {
        CK_TOKEN_INFO ti;
        if (fl->C_GetTokenInfo(slots[i], &ti) == 0) {
            char lab[33]; memcpy(lab, ti.label, 32); lab[32] = 0;
            for (int j = 31; j >= 0 && lab[j] == ' '; j--) lab[j] = 0;
            printf("token: %s\n", lab);
        }
    }
    fl->C_Finalize(NULL);
    return n > 0 ? 0 : 2;
}
EOF
    cc -o "${WORK_DIR}/p11test" "${WORK_DIR}/p11test.c"
    if "${WORK_DIR}/p11test" "${INSTALL_DIR}/libsrb-id-pkcs11.dylib"; then
        log "USPEH — kartica i token su vidljivi kroz modul!"
    else
        warn "Kartica nije očitana. Da li je u čitaču? Proverite:"
        warn "  system_profiler SPSmartCardsDataType"
    fi
else
    warn "Nema C kompajlera (xcode-select --install) — preskačem proveru kartice."
fi

cat <<'EOF'

────────────────────────────────────────────────────────────────────
GOTOVO. Prijava na https://eid.gov.rs (i SEF / eUprava preko njega):
  1. Otvorite (restartujte) Firefox — NE Chrome/Brave, na macOS-u ne mogu!
  2. Prijava kvalifikovanim elektronskim sertifikatom
  3. Izaberite sertifikat sa kartice → unesite PIN
     (PIN može biti zatražen dva puta — to je normalno, dva servera)

Posle svakog Firefox update-a vratite politike:
  cp ~/.local/lib/eid/policies.json "/Applications/Firefox.app/Contents/Resources/distribution/"

Dijagnostika: system_profiler SPSmartCardsDataType   (čitač + ATR kartice)
────────────────────────────────────────────────────────────────────
EOF
