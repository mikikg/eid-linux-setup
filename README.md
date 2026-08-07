# eID Linux Setup — prijava na eID.gov.rs ličnom kartom na Linuxu

Skript koji podešava **prijavu kvalifikovanim elektronskim sertifikatom sa
srpske lične karte** na portal [eid.gov.rs](https://eid.gov.rs) / eUprava iz
Chromium pregledača (Chrome, Brave, Chromium) na Debian/Ubuntu sistemima.

MUP-ov zvanični midlver (TrustEdgeID) postoji samo za Windows. Na Linuxu se
koristi open-source modul [srb-id-pkcs11](https://github.com/ubavic/srb-id-pkcs11),
ali za rad iz pregledača potrebne su zakrpe za stabilnost (predložene upstream u
[PR #27](https://github.com/ubavic/srb-id-pkcs11/pull/27)) — ovaj skript gradi
zakrpljen modul iz izvora i podešava ceo lanac.

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

## Zahvalnice

- [Nikola Ubavić](https://github.com/ubavic) za srb-id-pkcs11 i Baš Čelik
- Debagovano i zakrpljeno uz [Claude Code](https://claude.com/claude-code)
