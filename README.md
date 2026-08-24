# eID Linux Setup — prijava na eID.gov.rs ličnom kartom na Linuxu

Skript koji podešava **prijavu kvalifikovanim elektronskim sertifikatom sa
srpske lične karte** na portal [eid.gov.rs](https://eid.gov.rs) / eUprava iz
Chromium pregledača (Chrome, Brave, Chromium) na Debian/Ubuntu sistemima.

MUP-ov zvanični midlver (TrustEdgeID) postoji samo za Windows. Na Linuxu se
koristi open-source modul [srb-id-pkcs11](https://github.com/ubavic/srb-id-pkcs11),
ali za rad iz pregledača potrebne su zakrpe za stabilnost (predložene upstream u
[PR #27](https://github.com/ubavic/srb-id-pkcs11/pull/27)) — ovaj skript gradi
zakrpljen modul iz izvora i podešava ceo lanac.

Radi i na **macOS-u** (kroz Firefox) — v. [macOS sekciju](#macos-firefox) dole.

## Upotreba

```bash
git clone https://github.com/mikikg/eid-linux-setup
cd eid-linux-setup
./install-eid.sh
```

Zatim u pregledaču (deb verzija, **ne snap** — snap nema pristup čitaču!):
eid.gov.rs → Prijava kvalifikovanim elektronskim sertifikatom → izaberi
sertifikat → PIN. (PIN može biti zatražen dva puta — normalno, dva servera.)

## Šta skript radi

1. Instalira `pcscd`, CCID drajver i alate
2. Gradi `srb-id-pkcs11` + zakrpe ([patch](srb-id-pkcs11-robustness.patch)) i
   instalira modul u `~/.local/lib/eid/`
3. Registruje modul u NSS bazu pregledača (`~/.pki/nssdb`)
4. Uvozi MUP CA4 lanac sertifikata
5. Rešava poznate konflikte: Realtek 0bda:0169 kombo čitač (SD slot ometa
   smart karticu — udev pravilo), GNOME smartcard servis, OpenSC u NSS bazi

## Dijagnostika

```bash
pkcs11-tool --module ~/.local/lib/eid/libsrb-id-pkcs11.so -O   # vidi li karticu
journalctl -u pcscd                                            # greške čitača
SRB_ID_DEBUG=1 brave-browser 2>debug.log                       # statusni kodovi kartice
```

Detaljna hronika debagovanja i svih uzroka: [KAKO-JE-RESENO.md](KAKO-JE-RESENO.md).

## macOS (Firefox)

Na macOS-u Chromium pregledači (Chrome, Brave) koriste Keychain /
CryptoTokenKit i **ne mogu** da učitaju PKCS#11 modul — prijava radi
**samo iz Firefox-a**:

```bash
./install-eid-macos.sh
```

Skript gradi isti zakrpljeni modul (kao `.dylib`) i registruje ga, zajedno sa
MUP CA4 lancem, kroz Firefox enterprise `policies.json`. macOS varijanta je
jednostavnija od Linux one: PC/SC i CCID drajver su ugrađeni u sistem, pa
pcscd, udev pravila i ostala zaobilaženja ne trebaju (ni SD slot Realtek
kombo čitača ne smeta). Testirano na macOS 12 (Monterey), Intel, sa
Realtek 0bda:0169 čitačem — uspešna prijava na SEF (efaktura.mef.gov.rs).

**Posle svakog Firefox update-a** prijava prestaje da radi, jer update briše
`policies.json` iz app bundle-a. Skript ostavlja kopiju, samo je vratite:

```bash
cp ~/.local/lib/eid/policies.json "/Applications/Firefox.app/Contents/Resources/distribution/"
```

Dijagnostika na macOS-u:

```bash
system_profiler SPSmartCardsDataType    # vidi li sistem čitač i karticu (ATR)
```

## Zahvalnice

- [Nikola Ubavić](https://github.com/ubavic) za srb-id-pkcs11 i Baš Čelik
- Debagovano i zakrpljeno uz [Claude Code](https://claude.com/claude-code)
