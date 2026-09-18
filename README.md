# HOWTO – System Wipe Orchestrator v7.2

Complete handleiding voor het installeren, configureren en gebruiken van het wipe-script.

---

## 1. Overzicht

Dit script wist opslagmedia (HDD/SSD/NVMe) op een veilige, verifieerbare manier volgens NIST SP 800-88, met:

- Automatische detectie van schijftype (HDD / SSD / NVMe)
- Hardware-wipe waar mogelijk (Secure Erase, Sanitize, Cryptographic Erase)
- Software-overwrite als fallback
- Verificatie na wipe
- Audit-trail (JSON + CSV)
- Certificaat per schijf (TXT + PDF met logo)
- Klantgegevens via input-bestand
- Optionele cryptografische ondertekening

---

## 2. Vereisten

### Hardware / OS

- Linux (Debian 12, Ubuntu 22.04+ aanbevolen)
- Root-toegang
- Doelschijven **niet gemount** en **niet in gebruik**

### Verplichte software

```bash
apt-get update
apt-get install -y jq smartmontools nvme-cli hdparm util-linux openssl coreutils
```

### Optionele software (voor PDF-certificaat)

```bash
apt-get install -y weasyprint
```

> Het script installeert `weasyprint` automatisch als het nog niet aanwezig is.

---

## 3. Installatie

### Stap 1 – Script plaatsen

```bash
mkdir -p /root/wipe-audit
cp wipe.sh /root/wipe-audit/wipe.sh
chmod +x /root/wipe-audit/wipe.sh
```

### Stap 2 – Input-bestand aanmaken

```bash
cat > /root/wipe-audit/wipe-input.txt <<'EOF'
CUSTOMER="Acme BV"
TICKET="INC-2026-0042"
LOCATION="DC1-Rack A12"
OPERATOR="Jan Jansen"
ASSET_TAG="ASSET-9876"
LOGO_PATH="/root/wipe-audit/logo.png"
LOGO_WIDTH_MM=30
LOGO_HEIGHT_MM=30
LOGO_POSITION="top-right"
EOF
```

Alle velden zijn optioneel. Laat weg wat je niet nodig hebt.

### Stap 3 – Logo plaatsen

```bash
cp /pad/naar/logo.png /root/wipe-audit/logo.png
```

Aanbevolen: PNG met transparante achtergrond, vierkant, minimaal 300×300 px.

### Stap 4 – Controle

```bash
/root/wipe-audit/wipe.sh --help
```

---

## 4. Input-bestand – alle velden

| Veld | Betekenis | Voorbeeld |
|---|---|---|
| `CUSTOMER` | Klant/opdrachtgever | `"Acme BV"` |
| `TICKET` | Intern ticketnummer | `"INC-2026-0042"` |
| `LOCATION` | Datacenter, rack, locatie | `"DC1-Rack A12"` |
| `OPERATOR` | Uitvoerende medewerker | `"Jan Jansen"` |
| `ASSET_TAG` | Inventarislabel apparaat | `"ASSET-9876"` |
| `LOGO_PATH` | Pad naar logo | `"/root/wipe-audit/logo.png"` |
| `LOGO_WIDTH_MM` | Breedte logo in mm | `30` (= 3 cm) |
| `LOGO_HEIGHT_MM` | Hoogte logo in mm | `30` (= 3 cm) |
| `LOGO_POSITION` | Plaatsing in PDF | `top-right` |

**Posities:** `top-right` (default), `top-left`, `top-center`.

Regels die beginnen met `#` worden genegeerd. Onbekende keys geven een waarschuwing, geen fout.

---

## 5. Gebruik

### 5.1 Dry-run (aanbevolen om te testen)

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt --device sda --dry-run
```

Simuleert alles. Schrijft niets naar de schijf. Genereert géén PDF (dat gebeurt alleen bij een echte wipe).

### 5.2 Echte wipe

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt --device sda --force
```

Je moet `CONFIRM DESTROY` typen als bevestiging.

### 5.3 Meerdere schijven

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt \
    --device sda --device sdb --device nvme0n1 --force
```

### 5.4 Parallel (sneller)

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt \
    --device sda --device sdb --parallel 2 --force
```

### 5.5 Interactief (zonder `--device`)

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt --force
```

Het script toont alle beschikbare schijven en vraagt welke je wilt wissen.

### 5.6 Met ondertekend certificaat

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt --device sda --force --sign
```

Bij de eerste keer wordt een RSA-sleutelpaar gegenereerd in `/root/wipe-audit/`.

### 5.7 Met CSV-export

```bash
./wipe.sh --input /root/wipe-audit/wipe-input.txt --device sda --force --csv
```

---

## 6. Alle opties

| Optie | Effect |
|---|---|
| `--force` | Echt wissen (default is dry-run) |
| `--dry-run` | Simulatie |
| `--device DEV` | Doelschijf (meerdere keren te gebruiken) |
| `--input FILE` | Input-bestand met klantgegevens |
| `--parallel N` | N schijven parallel |
| `--no-safe` | Safe-mode uit (gevaarlijk!) |
| `--no-smart` | Geen SMART-logs |
| `--no-verify` | Geen verificatie na wipe |
| `--no-suspend` | Niet suspenden bij frozen SSD |
| `--nist` | NIST SP 800-88 (default) |
| `--dod3` | DoD 3-pass (legacy, niet aanbevolen) |
| `--csv` | CSV-export aan |
| `--sign` | Certificaat ondertekenen met OpenSSL |
| `--help` | Help tonen |

---

## 7. Wat gebeurt er tijdens een wipe

Per schijf doorloopt het script deze stappen:

1. **Detectie** – type (HDD/SSD/NVMe), model, serial, WWN, fingerprint
2. **Safety check** – is het root-schijf? Gemount? In allowlist?
3. **Bevestiging** – `CONFIRM DESTROY` intypen
4. **SMART pre-log** – gezondheid voor wipe
5. **Wipe** – afhankelijk van type:
   - **NVMe**: Cryptographic Erase → Secure Format → Sanitize → blkdiscard
   - **SSD**: Enhanced Secure Erase → Secure Erase → blkdiscard
   - **HDD**: NIST één-pass overwrite met nullen
6. **Verificatie** – leesbaarheid + steekproef op nullen
7. **SMART post-log** – gezondheid na wipe
8. **Audit + Certificaat** – JSON, CSV, TXT, PDF

---

## 8. Output

Na een run vind je in `/root/wipe-audit/`:

```
/root/wipe-audit/
├── wipe.log                       # Volledige log
├── audit.jsonl                    # JSON-lines audit
├── audit.csv                      # CSV audit (indien --csv)
├── session.json                   # Sessie-metadata
├── certificates/
│   ├── cert_<uuid>.txt            # Tekst-certificaat
│   ├── cert_<uuid>.txt.sha256     # Hash van TXT
│   ├── cert_<uuid>.txt.sig        # Ondertekening (indien --sign)
│   ├── cert_<uuid>.pdf            # PDF met logo
│   ├── cert_<uuid>.pdf.sha256     # Hash van PDF
│   └── cert_<uuid>.html           # HTML-bron
└── logs/
    ├── smart_pre_<serial>.log     # SMART voor wipe
    └── smart_post_<serial>.log    # SMART na wipe
```

---

## 9. Certificaat bekijken

```bash
# Nieuwste PDF
ls -t /root/wipe-audit/certificates/*.pdf | head -1

# Open PDF (indien GUI)
xdg-open /root/wipe-audit/certificates/cert_<uuid>.pdf

# Kopieer naar andere machine
scp /root/wipe-audit/certificates/cert_<uuid>.pdf user@host:/tmp/

# Bekijk tekst-certificaat
cat /root/wipe-audit/certificates/cert_<uuid>.txt
```

---

## 10. Veelvoorkomende problemen

### "Package 'weasyprint' has no installation candidate"

Debian 12 / Ubuntu 22.04+:

```bash
apt-get install -y python3-pip
pip3 install weasyprint
```

Of installeer `wkhtmltopdf` als alternatief:

```bash
apt-get install -y wkhtmltopdf xvfb
```

### "SSD is FROZEN"

Sommige SATA-SSD's zitten in "frozen" state. Oplossing: suspend + resume.

```bash
systemctl suspend
```

Daarna opnieuw wakker maken. Het script doet dit automatisch als `--no-suspend` niet is opgegeven.

Als suspend niet werkt: herstart met alleen stroom (geen data-kabel), of gebruik `--no-safe` (alleen blkdiscard).

### "Device is ROOT – BLOCKED"

Het script blokkeert automatisch de schijf waarop het OS staat. Dit is een veiligheidsmaatregel. Gebruik een live-USB of tweede systeem.

### PDF mist logo

Controleer:

```bash
ls -l /root/wipe-audit/logo.png
grep LOGO_PATH /root/wipe-audit/wipe-input.txt
```

Pad moet **absoluut** zijn en bestand moet leesbaar zijn voor root.

### Certificaat heeft geen klantgegevens

Controleer of input-bestand geladen is:

```bash
grep -E "CUSTOMER|TICKET" /root/wipe-audit/wipe-input.txt
```

En of je `--input` meegegeven hebt.

### Parallel wipe faalt

Probeer sequentieel (zonder `--parallel`) om te zien welke schijf problemen geeft. Meestal is een schijf gemount of in gebruik.

---

## 11. Best practices

1. **Altijd eerst dry-run** – controleer de output voordat je `--force` gebruikt.
2. **Gebruik een live-USB** – nooit het OS wissen vanaf de schijf waarop je werkt.
3. **Backup audit-directory** – `/root/wipe-audit/` bevat je bewijsmateriaal.
4. **Onderteken certificaten** – gebruik `--sign` voor juridische geldigheid.
5. **Test PDF-generatie vooraf** – met een dummy input-bestand op een test-schijf.
6. **Documenteer per batch** – gebruik per batch een eigen input-bestand met ticketnummer en klantnaam.
7. **Bewaar private key veilig** – `/root/wipe-audit/private.pem` is je bewijs-sleutel. Backup op aparte media.

---

## 12. Voorbeeld – complete workflow

```bash
# 1. Voorbereiding
cd /root/wipe-audit
vi wipe-input.txt
cp /pad/logo.png ./logo.png

# 2. Test run
./wipe.sh --input wipe-input.txt --device sda --dry-run

# 3. Identificeer schijven
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TYPE

# 4. Echte wipe
./wipe.sh --input wipe-input.txt --device sda --force --csv --sign

# 5. Controleer resultaat
ls -lh certificates/
cat certificates/cert_*.txt | head -50

# 6. Backup
tar czf /media/backup/wipe-$(date +%F).tgz \
    audit.jsonl audit.csv session.json certificates/ logs/ wipe.log
```

---

## 13. Exit codes

| Code | Betekenis |
|---|---|
| 0 | Succes |
| 1 | Algemene fout |
| 2 | Root vereist |
| 3 | Device niet gevonden |
| 4 | Device geblokkeerd |
| 5 | Wipe mislukt |
| 6 | Verificatie mislukt |
| 7 | Device frozen |
| 8 | Dependency ontbreekt |
| 9 | Gedeeltelijke failure |
| 10 | Ongeldige argumenten |
| 11 | Parallel failure |

---

## 14. Juridische opmerking

Het PDF-certificaat is een **technisch bewijsdocument**, geen juridisch document. Voor juridische geldigheid:

- Onderteken met `--sign` (OpenSSL)
- Bewaar private key veilig
- Zorg voor 4-ogen principe bij uitvoering
- Bewaar audit.jsonl onveranderlijk (WORM-storage aanbevolen)

NIST SP 800-88 Purge is de aanbevolen standaard voor moderne opslagmedia. DoD 3-pass is **legacy** en wordt door NIST niet meer aanbevolen.

---

## 15. Snelle referentie

```bash
# Dry-run
./wipe.sh -i wipe-input.txt -d sda --dry-run

# Echte wipe
./wipe.sh -i wipe-input.txt -d sda --force

# Meerdere schijven parallel
./wipe.sh -i wipe-input.txt -d sda -d sdb -d nvme0n1 -p 3 --force

# Met alles erop
./wipe.sh -i wipe-input.txt -d sda --force --csv --sign --parallel 1
```

**Klaar. Veel succes met de wipe.**
