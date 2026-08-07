# Prijava na eID.gov.rs ličnom kartom na Linuxu — kako je rešeno

Hronika debagovanja (07–08.08.2026) i tačan spisak svega što je promenjeno na
sistemu. Za javno objavljivanje koristi `install-eid.sh` iz ovog foldera; za
prijavu bagova autoru modula koristi `UPSTREAM-ISSUE.md` +
`srb-id-pkcs11-robustness.patch`.

## Simptom

Prijava kvalifikovanim sertifikatom na eid.gov.rs na Linuxu: nikad se ne
pojavi dijalog „Izaberite sertifikat", portal odmah vraća `error_403.html`.
Podrška predlaže brisanje keša na Windowsu. Kartica i čitač ispravni (CARID
čita karticu bez problema).

## Uzroci — svih OSAM, redom kako su otkrivani

1. **Nedostajao PKCS#11 middleware.** MUP-ov TrustEdgeID postoji samo za
   Windows; OpenSC ne podržava srpske lične karte („Unsupported card").
   Pregledač bukvalno nije imao odakle da ponudi sertifikat. Rešenje:
   open-source modul [srb-id-pkcs11](https://github.com/ubavic/srb-id-pkcs11)
   registrovan u NSS bazu pregledača (`~/.pki/nssdb`).

2. **Dve lične karte u opticaju.** Stara (008305255) sa sertifikatom
   isteklim 15.06.2026. i nova (015981155) sa važećim (10.06.2026–10.06.2031,
   MUP Gradjani CA 4). Server prihvata CA4 hijerarhiju (proveriti uvek sa:
   `openssl s_client -connect prijavas.eid.gov.rs:443` → „Acceptable client
   certificate CA names"). Teorija iz mejla podršci da CA4 nije na listi —
   netačna.

3. **Snap sandbox.** Snap Brave nema `pcscd` interfejs — fizički ne može do
   čitača, prijava u njemu nikad neće raditi. Koristiti deb pregledač.

4. **Pozadinski otimači kartice.** `gsd-smartcard` (GNOME servis za prijavu
   na računar karticom) + OpenSC registrovan u NSS bazi — oba šalju komande
   kartici paralelno sa pravim modulom. Servis maskiran, OpenSC izbačen iz
   NSS baze.

5. **Hardver: Realtek 0bda:0169 kombo čitač (smart kartica + SD slot).**
   Kernelovo prozivanje praznog SD slota (usb-storage) seče CCID transfere:
   pcscd log `Can't read all data (N out of 258)` → `T=1 state machine is
   DEAD` → kartica mrtva do vađenja. Rešenje: unbind usb-storage sa SD
   interfejsa (udev pravilo u install skriptu).

6. **Bag u modulu: C_GetSlotList osvežava listu čitača samo pri size-query
   pozivu** (`slot_list == null`). NSS/Chromium zovu i sa baferom → ako
   pregledač krene pre nego što se pcscd/čitač registruju, lista ostaje
   prazna zauvek → „nema sertifikata", bez ikakvog dijaloga.

7. **Bag u modulu: nema PC/SC transakcija + deadlock.** Višekomandne
   sekvence (čitanje sertifikata, potpis) nisu bile u transakcijama pa ih
   paralelni klijenti prepliću (vidi 4 i 5). Dodavanje transakcija bez
   in-process katanca pravi deadlock u libpcsclite (SCardConnect iz druge
   niti blokira dok traje transakcija, držeći globalni mutex biblioteke —
   uhvaćeno gdb-om). Konačno rešenje: globalni katanac oko SVAKOG PC/SC
   poziva + transakcija po operaciji.

8. **Bag u modulu: ustajala ručka posle reseta kartice.** Sesija pregledača
   otvori konekciju na startu, PIN dolazi minutima kasnije; u međuvremenu
   PC/SC resetuje karticu → `SCARD_W_RESET_CARD` → modul vraća
   `CKR_DEVICE_ERROR` na C_Login/C_Sign → browser: 403 ili
   `ERR_SSL_CLIENT_AUTH_SIGNATURE_FAILED`. Rešenje: reconnect + ponovna
   selekcija apleta + ponovljena komanda. (Ovo Windows midlveri odavno rade —
   zato tamo „samo radi".)

## Ključne dijagnostičke tehnike (za sledeći put)

- `pkcs11-tool --module X -O` — da li modul uopšte vidi karticu/sertifikate
- `journalctl -u pcscd` — T=1/CCID greške = problem čitač↔kartica
- Chromium `--log-net-log=fajl.json` — `SSL_CLIENT_CERT_PROVIDED
  {cert_count: 0}` = pregledač nema/ne vidi sertifikat
- `pkcs11-spy.so` između NSS-a i modula (PKCS11SPY env) — tačan poziv koji
  pukne i njegov CKR kod
- `SRB_ID_DEBUG=1` (naša zakrpa) — statusni kodovi kartice na stderr
- Višenitni test harness koji imitira browser (CKF_OS_LOCKING_OK + paralelno
  enumerisanje i polling) — `pkcs11-tool` je jednonitан i NE hvata ove bagove

## Šta je trajno promenjeno na ovoj mašini

| Šta | Gde |
|---|---|
| Zakrpljen modul | `/home/miki/lib/libsrb-id-pkcs11.so` (v0.5.0 + patch) |
| NSS registracija | `~/.pki/nssdb` (modul „Srb ID PKCS11"; OpenSC uklonjen) |
| MUP CA4 lanac | `~/.pki/nssdb` („MUP Gradjani CA 4", „MUP Root CA 4") |
| gsd-smartcard | maskiran (`systemctl --user unmask ...` vraća) |
| usb-storage SD slot | otkačen ručno — **posle restarta treba udev pravilo** iz `install-eid.sh` (sekcija 5a)! |
| Izvorni kod + patch | scratchpad sesije + `~/eid-linux-setup/srb-id-pkcs11-robustness.patch` |

## Sledeći koraci

1. **Upstream**: otvoriti issue(e) kod `ubavic/srb-id-pkcs11` sa tekstom iz
   `UPSTREAM-ISSUE.md` i ponuditi patch kao PR — ovim se pomaže svima koji
   pokušavaju prijavu iz pregledača.
2. **Udev pravilo**: pokrenuti `install-eid.sh` (ili bar sekciju 5a) da SD
   konflikt ostane rešen i posle restarta.
3. **Objavljivanje**: `install-eid.sh` + patch + ovaj dokument su spremni za
   javni repo (npr. `eid-linux-setup` na GitHubu).
