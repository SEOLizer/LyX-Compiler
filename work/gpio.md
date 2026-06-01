# GPIO-Anbindung in Lyx – Architektur & Umsetzungsfahrplan

> **Dokumenttyp:** Technischer Entwurf & Arbeitsplan
> **Zielsprache:** Lyx
> **Zielplattform:** Linux ARM64 (insb. Raspberry Pi 4)
> **Status:** Überarbeitete Fassung v2 (Mai 2026)

---

## 1. Einleitung

Da Lyx auf **Zero Dependencies** setzt, wird die C-Bibliothek komplett umgangen.  
Dieses Dokument beschreibt zwei Strategien zur GPIO-Ansteuerung:

- **Variante A (MMIO):** Direkter Speicherzugriff über `/dev/gpiomem` – maximal schnell, ideal für zeitkritische Anwendungen (z. B. Software-PWM).
- **Variante B (ioctl):** Zugriff über das Linux-GPIO-Character-Device `/dev/gpiochipX` – sicherer, vollständig im Userspace, kompatibel mit der `meta.safe`-Philosophie.

Zusätzlich wird ein **AI‑Native Typsicherheitskonzept** vorgestellt, das Fehler wie Kurzschlüsse oder falsche Pin-Modi bereits zur Compile-Zeit ausschließt.

> **Wichtiger ARM64-Hinweis:** Bei Variante A (MMIO) **muss** nach jedem Register-Schreibzugriff eine Memory-Barrier-Instruktion (`dmb sy`) emittiert werden. Andernfalls kann der Out-of-Order-Prozessor des BCM2711 die Schreibvorgänge umordnen und Hardware-Register landen in falscher Reihenfolge. Dieser Punkt ist in WP 2.0 ausführlich beschrieben.

---

## 2. Architekturübersicht

```
+-------------------------------------------------------+
|                Dein Lyx-Programm                       |
+-------------------------------------------------------+
                        |
                        v
+-------------------------------------------------------+
|            std.hardware.gpio (High-Level API)          |
+-------------------------------------------------------+
                        |
         +--------------+--------------+
         | (Variante A: MMIO)          | (Variante B: ioctl)
         v                             v
+-----------------------+   +-----------------------+
|  Memory-Mapping       |   |  Linux ioctl-Treiber  |
|  (/dev/gpiomem)       |   |  (/dev/gpiochipX)     |
+-----------------------+   +-----------------------+
         |                             |
         +----------+ +----------------+
                    | |
                    v v
+-------------------------------------------------------+
|              Linux-Kernel-Syscalls                     |
|        (sys_openat, sys_mmap, sys_ioctl, sys_close)   |
+-------------------------------------------------------+
```

---

## 3. Fahrplan – Arbeitspakete (WPs)

| WP | Titel | Aufwand (geschätzt) | Priorität |
|----|-------|---------------------|-----------|
| 1  | Low-Level-Syscalls & Compiler-Intrinsics | 1 PT | 🔴 Hoch |
| 2.0 | Memory-Barrier-Intrinsic (ARM64) | 0,5 PT | 🔴 Hoch |
| 2  | Variante A – MMIO-Grundgerüst | 3 PT | 🔴 Hoch |
| 3.0 | Hilfsfunktionen (CopyStringToBuf, DelayMicroseconds) | 1 PT | 🔴 Hoch |
| 3  | Variante B – ioctl-Grundgerüst | 3 PT | 🔴 Hoch |
| 4  | AI‑Native Typsicherheit | 2 PT | 🔴 Geblockt (Generics fehlen) |
| 5  | Erweiterungen (Pull‑Up/Down, Interrupts, PWM) | 4 PT | 🟢 Niedrig |

*(PT = Personen-Tage, Richtwerte)*

---

### WP 1: Low-Level-Syscalls & Compiler-Intrinsics bereitstellen

#### Info

##### 1a – Syscalls (ARM64/AArch64)

| Syscall-Name | ARM64-Nr. | Zweck |
|--------------|-----------|-------|
| `sys_openat` | 56 | Öffnet `/dev/gpiomem` oder `/dev/gpiochip0` |
| `sys_mmap` | 222 | Projiziert physischen GPIO-Speicher in den Prozessadressraum |
| `sys_munmap` | 215 | Gibt eine Speicherprojektion wieder frei |
| `sys_ioctl` | 29 | Sendet Steuerbefehle an den GPIO-Treiber |
| `sys_close` | 57 | Schließt Dateideskriptoren |
| `sys_read` | 63 | Liest von einem Dateideskriptor (für spätere Interrupts) |
| `sys_poll` | 32 | Wartet auf Ereignisse auf einem Dateideskriptor |

##### 1b – Compiler-Intrinsics (keine Syscalls)

Für MMIO werden zusätzlich **zwei ARM64-Barriere-Intrinsics** benötigt. Es handelt sich nicht um Syscalls – der Compiler muss die entsprechende ARM64-Instruktion direkt an der Aufrufstelle einbetten:

| Intrinsic | ARM64-Instruktion | Zweck |
|-----------|-------------------|-------|
| `mem_barrier()` | `dmb sy` | Full-System-Memory-Barrier: stellt sicher, dass alle vorherigen Speicherzugriffe abgeschlossen sind, bevor neue beginnen |
| `inst_barrier()` | `isb` | Instruction-Sync-Barrier: flusht die Instruktions-Pipeline (z. B. nach MMU-Konfiguration) |

```lyx
// Compiler-Intrinsics – werden zu Inline-Instruktionen expandiert
intrinsic procedure mem_barrier();  // ARM64: dmb sy
intrinsic procedure inst_barrier(); // ARM64: isb
```

#### Grund
Ohne die Syscalls ist keine direkte Hardware-Kommunikation möglich. Ohne `mem_barrier()` können MMIO-Schreibvorgänge auf dem BCM2711 (Cortex-A72, Out-of-Order) in falscher Reihenfolge beim Peripherie-Controller ankommen.

#### Abnahmekriterien
1. Jeder Syscall ist als Lyx-Intrinsic (`sys_*`) deklariert und lässt sich in einem minimalen Testprogramm aufrufen.
2. Der Compiler erzeugt für jeden `sys_*`-Aufruf die korrekte ARM64-`svc`-Instruktion mit der passenden Nummer in `x8`.
3. `mem_barrier()` erzeugt im Disassembly exakt eine `dmb sy`-Instruktion ohne umliegenden Overhead.
4. Ein Testprogramm kann `/dev/null` per `sys_openat` öffnen und per `sys_close` wieder schließen.

---

### WP 2.0: Memory-Barrier-Konzept für MMIO

#### Info

ARM64-Prozessoren (wie der Cortex-A72 im BCM2711) sind **Out-of-Order**-Prozessoren. Bei MMIO-Zugriffen bedeutet das:

- Schreibvorgänge in Register können vom Prozessor **umgeordnet** werden.
- Ohne explizite Barrieren kann z. B. `GPSET` vor dem Abschluss von `GPFSEL` (Modus-Setzung) ankommen.
- Dies führt zu schwer reproduzierbaren Hardware-Bugs.

**Faustregeln für dieses Modul:**

| Situation | Barriere |
|-----------|----------|
| Nach jedem Schreibzugriff auf ein GPIO-Register | `mem_barrier()` |
| Nach `sys_mmap` (vor erstem Register-Zugriff) | `mem_barrier()` |
| Zwischen SetPinMode und erstem WritePin/ReadPin | `mem_barrier()` |
| Lese-Zugriffe (ReadPin) | keine Barriere nötig, da `GPLEV` ein reines Leseregister ist |

#### Grund
Ohne Barrieren können inkonsistente GPIO-Zustände auftreten, die auf normalen Testaufbauten (geringer Takt, einzelner Kern) nie reproduzierbar sind, auf realer Hardware jedoch sporadisch auftreten.

#### Abnahmekriterien
1. Jede schreibende MMIO-Funktion (`SetPinMode`, `WritePin`, `SetPullMode`) endet mit `mem_barrier()`.
2. Ein Disassembly-Test prüft, dass `dmb sy` unmittelbar nach jedem Register-Schreibzugriff erscheint.

---

### WP 2: Variante A – MMIO-Grundgerüst (Direct Register Access)

Dieser Weg ist perfekt für zeitkritische Anwendungen, da nach der Initialisierung **kein Context-Switch** in den Kernel mehr nötig ist.

---

#### WP 2.1: Hardware-Adressen definieren

##### Info
Jeder Raspberry Pi hat eine andere Basisadresse für die Peripherie. Für den Pi 4 (BCM2711) lauten die relevanten Werte:

```lyx
// std/hardware/platform/rpi4.lyx
module rpi4;

const
    PERIPHERAL_BASE = 0xFE000000;
    GPIO_BASE       = PERIPHERAL_BASE + 0x200000;   // 0xFE200000

    // Register-Offsets (jedes Register ist 32 Bit / 4 Bytes groß)
    GPFSEL0 = 0x00;   // Function Select 0  (Pins  0 – 9)
    GPFSEL1 = 0x04;   // Function Select 1  (Pins 10 – 19)
    GPFSEL2 = 0x08;   // Function Select 2  (Pins 20 – 29)
    GPFSEL3 = 0x0C;   // Function Select 3  (Pins 30 – 39)
    GPFSEL4 = 0x10;   // Function Select 4  (Pins 40 – 49)
    GPFSEL5 = 0x14;   // Function Select 5  (Pins 50 – 53)

    GPSET0  = 0x1C;   // Output Set   0 (Pins  0 – 31)
    GPSET1  = 0x20;   // Output Set   1 (Pins 32 – 53)
    GPCLR0  = 0x28;   // Output Clear 0 (Pins  0 – 31)
    GPCLR1  = 0x2C;   // Output Clear 1 (Pins 32 – 53)
    GPLEV0  = 0x34;   // Level Read   0 (Pins  0 – 31)
    GPLEV1  = 0x38;   // Level Read   1 (Pins 32 – 53)

    GPPUD       = 0x94;   // Pull-Up/Down Control (BCM2711 legacy)
    GPPUDCLK0   = 0x98;   // Pull-Up/Down Clock 0
    GPPUDCLK1   = 0x9C;   // Pull-Up/Down Clock 1

    // BCM2711 verwendet ein neues Pull-Register ab Revision 1.2:
    GPIO_PUP_PDN_CNTRL_REG0 = 0xE4;   // Neues Pull-Up/Down-Format (Pins  0–15)
    GPIO_PUP_PDN_CNTRL_REG1 = 0xE8;   // Neues Pull-Up/Down-Format (Pins 16–31)
    GPIO_PUP_PDN_CNTRL_REG2 = 0xEC;   // Neues Pull-Up/Down-Format (Pins 32–47)
    GPIO_PUP_PDN_CNTRL_REG3 = 0xF0;   // Neues Pull-Up/Down-Format (Pins 48–53)

    // Plattform-Fähigkeit: welches Pull-Register-Format ist aktiv?
    HAS_NEW_PULL_REGS = true;          // false für BCM2711 Rev < 1.2
```

> **Hinweis:** Ab Raspberry Pi 4 Rev 1.2 sind die Pull-Widerstände über das neue `GPIO_PUP_PDN_CNTRL_REG`-Register zu konfigurieren. Beide Varianten sollten unterstützt werden. Die vier Register REG0–REG3 wurden ergänzt (REG2 und REG3 fehlten in der Vorversion).

##### Grund
Ohne die korrekten physischen Adressen und Register-Offsets kann der MMIO-Zugriff nicht funktionieren. Falsche Adressen führen zu Bus-Fehlern oder stummen Schreibfehlern.

##### Abnahmekriterien
1. Die Konstanten sind im Modul `std/hardware/platform/rpi4.lyx` definiert.
2. Ein Test liest die Werte zur Compile-Zeit aus und vergleicht sie mit der BCM2711-Dokumentation.
3. Für andere Plattformen (z. B. RPi 3, RPi 5) existieren separate Plattform-Module.

---

#### WP 2.2: Initialisierung und Freigabe (`InitGPIO` / `CloseGPIO`)

##### Info

```lyx
// std/hardware/gpio.lyx
module gpio;

import rpi4;

type
    PinMode  = enum (Input, Output);
    PinState = enum (Low, High);
    PullMode = enum (None, PullDown, PullUp);

var
    gpio_mem:   ^DWord = nil;
    is_mapped:  Boolean = false;

procedure InitGPIO(): Boolean;
var
    fd: Int;
begin
    fd := sys_openat(AT_FDCWD, "/dev/gpiomem", O_RDWR or O_SYNC);
    if fd < 0 then
    begin
        // Fallback: /dev/mem (erfordert Root-Rechte)
        fd := sys_openat(AT_FDCWD, "/dev/mem", O_RDWR or O_SYNC);
        if fd < 0 then return false;
    end;

    gpio_mem := sys_mmap(nil, 4096, PROT_READ or PROT_WRITE, MAP_SHARED, fd, GPIO_BASE);
    sys_close(fd); // fd kann nach mmap geschlossen werden

    if (gpio_mem == MAP_FAILED) or (gpio_mem == nil) then
    begin
        gpio_mem := nil;
        return false;
    end;

    // Sicherstellen, dass das Mapping vollständig etabliert ist,
    // bevor der erste Register-Zugriff stattfindet.
    mem_barrier();

    is_mapped := true;
    return true;
end;

procedure CloseGPIO();
begin
    if is_mapped and (gpio_mem != nil) then
    begin
        mem_barrier(); // alle ausstehenden Schreibvorgänge abschließen
        sys_munmap(gpio_mem, 4096);
        gpio_mem  := nil;
        is_mapped := false;
    end;
end;
```

##### Grund
- **InitGPIO:** Muss vor jedem GPIO-Zugriff aufgerufen werden. Öffnet `/dev/gpiomem` (kein Root nötig) und legt ein Mapping der physischen Register an. Fallback auf `/dev/mem`, falls `/dev/gpiomem` nicht existiert.
- **CloseGPIO:** Gibt das Mapping frei (`munmap`). Ohne dies bleibt der Speicher bis zum Prozessende belegt.
- Die `is_mapped`-Flagge verhindert doppeltes Freigeben.
- `mem_barrier()` nach `mmap` ist auf ARM64 erforderlich, um Race-Conditions zwischen Mapping-Etablierung und erstem Zugriff zu vermeiden.

##### Abnahmekriterien
1. `InitGPIO` gibt `true` zurück, wenn das Mapping erfolgreich war (sowohl mit als auch ohne `/dev/gpiomem`).
2. `CloseGPIO` gibt das Mapping frei; nachfolgende Zugriffe auf `gpio_mem` schlagen fehl.
3. Ein Test, der `InitGPIO` → `CloseGPIO` → `InitGPIO` aufruft, schlägt nicht fehl (doppelte Initialisierung ist sicher).
4. Bei fehlendem `/dev/gpiomem` wird automatisch auf `/dev/mem` umgeschaltet.

---

#### WP 2.3: Pin-Modus setzen (`SetPinMode`)

##### Info

```lyx
procedure SetPinMode(pin: Byte; mode: PinMode): Boolean;
var
    reg_index: Byte;
    bit_shift: Byte;
    mask: DWord;
begin
    if (pin > 53) or (not is_mapped) then return false;

    // Jeder Pin belegt 3 Bits im jeweiligen FSEL-Register
    reg_index := pin / 10;
    bit_shift := (pin mod 10) * 3;
    mask      := 7 shl bit_shift;

    case mode of
        PinMode.Input:
            // 000 = Input: alle 3 Bits löschen
            (gpio_mem + reg_index)^ := (gpio_mem + reg_index)^ and not(mask);
        PinMode.Output:
            // 001 = Output
            (gpio_mem + reg_index)^ := ((gpio_mem + reg_index)^ and not(mask)) or (1 shl bit_shift);
    end;

    // ARM64: Schreibvorgang zum Peripherie-Controller durchsetzen
    mem_barrier();

    return true;
end;
```

##### Grund
Jeder GPIO-Pin kann als Ein- oder Ausgang konfiguriert werden. Die drei Bits pro Pin im FSEL-Register codieren den Modus (`000` = Input, `001` = Output, `100`–`111` = Alternativfunktionen). `mem_barrier()` am Ende stellt sicher, dass der Modus-Schreibvorgang abgeschlossen ist, bevor ein nachfolgendes `WritePin` oder `ReadPin` ausgeführt wird.

##### Abnahmekriterien
1. `SetPinMode(18, Input)` konfiguriert Pin 18 als Eingang.
2. `SetPinMode(18, Output)` konfiguriert Pin 18 als Ausgang.
3. Bei ungültiger Pin-Nummer (>53) oder fehlendem Mapping wird `false` zurückgegeben.
4. Ein Oszilloskop oder ein zweiter Pin bestätigt den Moduswechsel.
5. Disassembly zeigt `dmb sy` unmittelbar nach dem FSEL-Schreibzugriff.

---

#### WP 2.4: Pin schreiben und lesen (`WritePin` / `ReadPin`)

##### Info

```lyx
procedure WritePin(pin: Byte; state: PinState): Boolean;
begin
    if (pin > 53) or (not is_mapped) then return false;

    if pin < 32 then
    begin
        if state == PinState.High then
            (gpio_mem + (GPSET0 / 4))^ := (1 shl pin)
        else
            (gpio_mem + (GPCLR0 / 4))^ := (1 shl pin);
    end
    else
    begin
        if state == PinState.High then
            (gpio_mem + (GPSET1 / 4))^ := (1 shl (pin - 32))
        else
            (gpio_mem + (GPCLR1 / 4))^ := (1 shl (pin - 32));
    end;

    // ARM64: Schreibvorgang zum GPIO-Controller durchsetzen
    mem_barrier();

    return true;
end;

// Gibt den aktuellen Pegel zurück; nil bei ungültigem Pin oder fehlendem Mapping.
function ReadPin(pin: Byte): Nullable<PinState>;
begin
    if (pin > 53) or (not is_mapped) then return nil;

    // Leseregister (GPLEV) benötigen keine Barriere – sie spiegeln
    // den physischen Zustand und haben keine Schreib-Seiteneffekte.
    if pin < 32 then
    begin
        if ((gpio_mem + (GPLEV0 / 4))^ and (1 shl pin)) != 0 then
            return PinState.High
        else
            return PinState.Low;
    end
    else
    begin
        if ((gpio_mem + (GPLEV1 / 4))^ and (1 shl (pin - 32))) != 0 then
            return PinState.High
        else
            return PinState.Low;
    end;
end;
```

> **Hinweis:** Der Ausdruck `GPSET0 / 4` wandelt das Byte-Offset in einen DWord-Offset um, da `gpio_mem` als `^DWord` deklariert ist (Integer-Division).

> **Nullable-Konvention:** `return nil` signalisiert den Fehlerfall; `return PinState.X` liefert einen gültigen Wert. Der Aufrufer prüft den Rückgabewert gegen `nil`.

##### Grund
- **WritePin:** GPSET/GPCLR sind **Write-1-to-set**-Register – das verhindert Race-Conditions zwischen mehreren Pins. `mem_barrier()` am Ende erzwingt, dass der GPIO-Controller den Pegel übernimmt, bevor eine nachfolgende Operation (z. B. ReadPin) ausgeführt wird.
- **ReadPin:** Liest den aktuellen Pegel eines Pins über das `GPLEV`-Register aus. Keine Barriere nötig, da das Register den physischen Zustand widerspiegelt und kein Schreib-Seiteneffekt entsteht.

##### Abnahmekriterien
1. `WritePin(18, High)` legt am Pin 18 eine Spannung von ~3,3 V an.
2. `WritePin(18, Low)` legt am Pin 18 Masse-Potential an.
3. `ReadPin(18)` gibt den korrekten Pegel zurück (mit Pull-Down oder externer Beschaltung).
4. Bei Pins >31 werden die korrekten Register (`GPSET1`/`GPCLR1`/`GPLEV1`) verwendet.
5. Bei Fehlern (Pin >53, nicht initialisiert) wird `false` bzw. `nil` zurückgegeben.
6. Disassembly zeigt `dmb sy` nach jedem GPSET/GPCLR-Schreibzugriff.

---

#### WP 2.5: Pull-Up/Pull-Down konfigurieren (`SetPullMode`)

##### Info

```lyx
procedure SetPullMode(pin: Byte; mode: PullMode): Boolean;
var
    reg_index: Byte;
    bit_shift: Byte;
    r: ^DWord;
begin
    if (pin > 53) or (not is_mapped) then return false;

    if HAS_NEW_PULL_REGS then
    begin
        // BCM2711 neues Register-Format (Rev >= 1.2)
        // 2 Bits pro Pin: 00=None, 01=PullDown, 10=PullUp
        reg_index := pin / 16;
        bit_shift := (pin mod 16) * 2;
        r := gpio_mem + (GPIO_PUP_PDN_CNTRL_REG0 / 4) + reg_index;

        case mode of
            PullMode.None:      r^ := (r^ and not(3 shl bit_shift)) or (0 shl bit_shift);
            PullMode.PullDown:  r^ := (r^ and not(3 shl bit_shift)) or (1 shl bit_shift);
            PullMode.PullUp:    r^ := (r^ and not(3 shl bit_shift)) or (2 shl bit_shift);
        end;
    end
    else
    begin
        // Legacy BCM2835/BCM2711 Rev < 1.2: 3-Schritt-Protokoll
        // Schritt 1: Modus in GPPUD schreiben
        case mode of
            PullMode.None:      (gpio_mem + (GPPUD / 4))^ := 0;
            PullMode.PullDown:  (gpio_mem + (GPPUD / 4))^ := 1;
            PullMode.PullUp:    (gpio_mem + (GPPUD / 4))^ := 2;
        end;
        mem_barrier();

        // Schritt 2: Clock-Bit für den gewünschten Pin setzen (mind. 150 Zyklen halten)
        if pin < 32 then
            (gpio_mem + (GPPUDCLK0 / 4))^ := (1 shl pin)
        else
            (gpio_mem + (GPPUDCLK1 / 4))^ := (1 shl (pin - 32));
        mem_barrier();

        // Schritt 3: GPPUD und Clock-Bits zurücksetzen
        (gpio_mem + (GPPUD / 4))^ := 0;
        mem_barrier();
        if pin < 32 then
            (gpio_mem + (GPPUDCLK0 / 4))^ := 0
        else
            (gpio_mem + (GPPUDCLK1 / 4))^ := 0;
    end;

    mem_barrier();
    return true;
end;
```

> **Hinweis:** Das Legacy-Protokoll wurde vollständig implementiert (war in der Vorversion nicht enthalten). Die Plattform-Konstante `HAS_NEW_PULL_REGS` steuert die Auswahl zur Compile-Zeit.

##### Grund
Ohne Pull-Widerstände sind floating Inputs undefiniert und verbrauchen unnötig Strom. Das Legacy-Protokoll ist auf RPi 3 und frühen RPi-4-Boards zwingend erforderlich.

##### Abnahmekriterien
1. `SetPullMode(23, PullUp)` aktiviert den internen Pull-Up an Pin 23.
2. Ein Multimeter bestätigt ~3,3 V am Pin (bei nicht extern beschaltetem Eingang).
3. `SetPullMode(23, PullDown)` zieht den Pin auf Masse.
4. Der Modus `None` deaktiviert beide Pull-Widerstände.
5. Das Legacy-Protokoll (GPPUD/GPPUDCLK) wird korrekt auf Boards mit `HAS_NEW_PULL_REGS = false` ausgeführt.

---

### WP 3.0: Hilfsfunktionen

Diese Funktionen werden von WP 3 (ioctl) und WP 5 (Erweiterungen) benötigt und müssen vor diesen WPs implementiert sein.

#### Info

```lyx
// std/hardware/gpio_util.lyx
module gpio_util;

// Kopiert einen Null-terminierten String in einen Puffer fester Größe.
// Schreibt höchstens max_len-1 Zeichen + Null-Terminator.
procedure CopyStringToBuf(src: ^Char; dst: ^Char; max_len: DWord);
var
    i: DWord;
begin
    i := 0;
    while (i < max_len - 1) and (src[i] != #0) do
    begin
        dst[i] := src[i];
        i := i + 1;
    end;
    dst[i] := #0; // Null-Terminator sicherstellen
end;

// Wartet mindestens delay_us Mikrosekunden durch aktives Warten.
// Nutzt ARM64-Systemtimer-Register (CNTPCT_EL0) für Präzision.
// Genauigkeit: ± 1 µs (abhängig von Systemlast und Taktteiler).
procedure DelayMicroseconds(delay_us: DWord);
var
    start:   UInt64;
    elapsed: UInt64;
    freq:    UInt64;
    ticks:   UInt64;
begin
    // CNTFRQ_EL0 enthält die Systemtimer-Frequenz (meist 54 MHz auf RPi4)
    freq := read_cntfrq_el0();
    // CNTPCT_EL0 ist der aktuelle Zählerstand
    start := read_cntpct_el0();
    ticks := (freq / 1_000_000) * delay_us;

    repeat
        elapsed := read_cntpct_el0() - start;
    until elapsed >= ticks;
end;
```

> **Hinweis:** `read_cntfrq_el0()` und `read_cntpct_el0()` sind ARM64-Compiler-Intrinsics, die `mrs x0, CNTFRQ_EL0` bzw. `mrs x0, CNTPCT_EL0` emittieren. Sie benötigen kein Kernel-Interface. Für sehr kurze Delays (< 1 µs) ist ein `nop`-basierter Busy-Wait präziser.

#### Abnahmekriterien
1. `CopyStringToBuf("lyx-gpio", buf, 32)` schreibt genau 9 Bytes (8 Zeichen + NUL).
2. Bei `max_len = 4` wird nach 3 Zeichen abgeschnitten und ein NUL-Terminator gesetzt.
3. `DelayMicroseconds(1000)` wartet mindestens 1 ms (messbar mit Oszilloskop oder `clock_gettime`-Syscall).
4. `DelayMicroseconds(0)` kehrt sofort zurück.

---

### WP 3: Variante B – Linux-ioctl (GPIO-Char-Device)

Dieser Weg nutzt das Linux-Standard-Interface `/dev/gpiochipX`. Er ist **langsamer** (jeder Zugriff ist ein ioctl-Syscall), dafür **sicherer** (kein direktes Memory-Mapping, Zugriffskontrolle über Dateirechte).

---

#### WP 3.1: ioctl-Strukturen und -Konstanten definieren

##### Info

```lyx
// std/hardware/gpio_ioctl.lyx
module gpio_ioctl;

// --- ioctl-Konstanten (Linux-GPIO-v2-API) ---
const
    GPIO_V2_LINE_NUM_ATTRS_MAX  = 10;
    GPIO_V2_LINES_MAX           = 64;
    GPIO_MAX_NAME_SIZE          = 32;

    // Request-Flags
    GPIO_V2_LINE_FLAG_INPUT          = 1 shl 0;
    GPIO_V2_LINE_FLAG_OUTPUT         = 1 shl 1;
    GPIO_V2_LINE_FLAG_ACTIVE_LOW     = 1 shl 2;
    GPIO_V2_LINE_FLAG_PULL_UP        = 1 shl 3;
    GPIO_V2_LINE_FLAG_PULL_DOWN      = 1 shl 4;
    GPIO_V2_LINE_FLAG_EDGE_RISING    = 1 shl 5;
    GPIO_V2_LINE_FLAG_EDGE_FALLING   = 1 shl 6;
    GPIO_V2_LINE_FLAG_EDGE_BOTH      = 1 shl 7;

    // IOCTL-Codes – berechnet nach Linux-_IOW/_IOR/_IOWR-Makros:
    //   _IOW (write):  (0x40000000 | (size << 16) | (type << 8) | nr)
    //   _IOR (read):   (0x80000000 | (size << 16) | (type << 8) | nr)
    //   _IOWR (beide): (0xC0000000 | (size << 16) | (type << 8) | nr)
    //
    // type = 0xB4, gpiochip_info = 68 Bytes (0x44), gpio_v2_line_request = 180 Bytes (0xB4)
    // gpio_v2_line_values = 24 Bytes (0x18)
    //
    // ACHTUNG: Diese Werte gelten für Linux >= 5.10 mit GPIO-v2-API.
    // Bei älteren Kerneln (<5.10) existiert nur die v1-API mit anderen Codes.
    GPIO_GET_CHIPINFO_IOCTL_V2       = 0x8044B401;  // _IOR(0xB4, 0x01, gpiochip_info)
    GPIO_V2_GET_LINE_IOCTL           = 0xC0B4B405;  // _IOWR(0xB4, 0x05, gpio_v2_line_request)
    GPIO_V2_LINE_SET_VALUES_IOCTL    = 0x4018B40B;  // _IOW(0xB4, 0x0B, gpio_v2_line_values)
    GPIO_V2_LINE_GET_VALUES_IOCTL    = 0xC018B40C;  // _IOWR(0xB4, 0x0C, gpio_v2_line_values)

// --- Typdefinitionen ---

type
    GpioChipInfo = record
        name:   array[0..31] of Char;    // Name des Chips
        label_: array[0..31] of Char;    // Label des Treibers
        lines:  DWord;                   // Anzahl der verfügbaren Pins
    end;

    GpioV2LineAttribute = record
        id:     DWord;
        padding: DWord;
        value:  UInt64;
    end;

    GpioV2LineConfig = record
        flags:      UInt64;
        num_attrs:  DWord;
        padding:    array[0..2] of DWord;
        attrs:      array[0..GPIO_V2_LINE_NUM_ATTRS_MAX-1] of GpioV2LineAttribute;
    end;

    GpioV2LineRequest = record
        lines:      array[0..GPIO_V2_LINES_MAX-1] of DWord;
        num_lines:  DWord;
        config:     GpioV2LineConfig;
        consumer:   array[0..GPIO_MAX_NAME_SIZE-1] of Char;
        fd:         Int;    // Rückgabe vom Kernel (Dateideskriptor für die Line)
    end;

    GpioV2LineValues = record
        mask:   UInt64;
        bits:   UInt64;
    end;
```

> **Wichtig:** Die IOCTL-Codes sind inline dokumentiert, wie sie sich aus den Linux-Makros ergeben. Bei einer Kernel-Umgebung ohne GPIO-v2-Support (< 5.10) muss auf die v1-API zurückgefallen werden. Die Werte sollten zur Buildzeit per Script aus `/usr/include/linux/gpio.h` extrahiert und mit diesen Konstanten verglichen werden.

##### Grund
Um die Linux-GPIO-v2-API nutzen zu können, müssen die C-Strukturen eins-zu-eins in Lyx-Typen abgebildet werden. Die korrekte Größe und das Padding sind kritisch – ein falsches Layout führt zu stummen Fehlern.

##### Abnahmekriterien
1. Alle Typen haben die exakt gleiche Größe wie ihre C-Pendants (Vergleich per `sizeof` gegen einen C-Referenz-Build).
2. Die IOCTL-Konstanten stimmen mit den Werten aus `/usr/include/linux/gpio.h` überein (automatisierter Buildzeit-Check).
3. Ein Testprogramm kann `GpioChipInfo` mit Nullen initialisieren und ausgeben.

---

#### WP 3.2: Chip-Info auslesen

##### Info

```lyx
function GetChipInfo(chip_path: ^Char): Nullable<GpioChipInfo>;
var
    fd: Int;
    info: GpioChipInfo;
begin
    fd := sys_openat(AT_FDCWD, chip_path, O_RDWR);
    if fd < 0 then return nil;

    if sys_ioctl(fd, GPIO_GET_CHIPINFO_IOCTL_V2, addr(info)) < 0 then
    begin
        sys_close(fd);
        return nil;
    end;

    sys_close(fd);
    return info;
end;
```

##### Grund
Ein Chip-Info-Aufruf ist der erste Schritt, um die verfügbaren GPIO-Lines zu ermitteln – wichtig für die Fehlerbehandlung (z. B. „Chip nicht gefunden").

##### Abnahmekriterien
1. `GetChipInfo("/dev/gpiochip4")` liefert die korrekte Anzahl Lines (z. B. 54 auf Pi 4).
2. Bei nicht existierendem Pfad wird `nil` zurückgegeben.

---

#### WP 3.3: Line-Request und Werte setzen/lesen

##### Info

```lyx
function RequestLines(chip_path: ^Char; pins: array[] of DWord; flags: UInt64; consumer: ^Char): Int;
var
    fd: Int;
    req: GpioV2LineRequest;
    i: DWord;
begin
    // Sicherheits-Check: die v2-API erlaubt maximal GPIO_V2_LINES_MAX Pins pro Request
    if pins.Length > GPIO_V2_LINES_MAX then return -1;

    fd := sys_openat(AT_FDCWD, chip_path, O_RDWR);
    if fd < 0 then return -1;

    // Request-Struktur mit Nullen initialisieren
    req := zero(GpioV2LineRequest);
    req.num_lines := pins.Length;
    req.config.flags := flags;
    for i := 0 to pins.Length - 1 do
        req.lines[i] := pins[i];

    // Consumer-Label kopieren (max. GPIO_MAX_NAME_SIZE-1 Zeichen + NUL)
    CopyStringToBuf(consumer, addr(req.consumer), GPIO_MAX_NAME_SIZE);

    if sys_ioctl(fd, GPIO_V2_GET_LINE_IOCTL, addr(req)) < 0 then
    begin
        sys_close(fd);
        return -1;
    end;

    sys_close(fd); // Chip-Fd schließen, Line-Fd bleibt offen
    return req.fd; // Rückgabe: Dateideskriptor für die Line
end;

function SetLineValues(line_fd: Int; mask: UInt64; bits: UInt64): Boolean;
var
    values: GpioV2LineValues;
begin
    values.mask := mask;
    values.bits := bits;

    if sys_ioctl(line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, addr(values)) < 0 then
        return false;

    return true;
end;

// Gibt die aktuellen Pegel der angeforderten Pins zurück; nil bei Fehler.
function GetLineValues(line_fd: Int; mask: UInt64): Nullable<UInt64>;
var
    values: GpioV2LineValues;
begin
    values.mask := mask;
    values.bits := 0;

    if sys_ioctl(line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, addr(values)) < 0 then
        return nil;

    return values.bits;
end;

procedure ReleaseLine(line_fd: Int);
begin
    sys_close(line_fd);
end;
```

##### Grund
Dies ist das Kernstück der ioctl-Variante. Der Bounds-Check `pins.Length > GPIO_V2_LINES_MAX` verhindert, dass der Kernel einen Buffer-Overflow in der Request-Struktur sieht (stilles Abschneiden wäre schwer debugbar).

##### Abnahmekriterien
1. `RequestLines("/dev/gpiochip4", [18, 23], OUTPUT)` gibt einen gültigen Dateideskriptor zurück.
2. Ein Aufruf mit mehr als 64 Pins gibt sofort `-1` zurück (ohne Kernel-Kontakt).
3. `SetLineValues(fd, mask, bits)` setzt die entsprechenden Pins.
4. `GetLineValues(fd, mask)` liest die aktuellen Pegel aus; bei Fehler wird `nil` zurückgegeben.
5. `ReleaseLine(fd)` schließt den Dateideskriptor.
6. Nach dem Freigeben schlagen weitere Zugriffe fehl.

---

### WP 4: AI‑Native Typsicherheit – Compiler-Garantien für Pin-Typen

> **Status: 🔴 Geblockt** – Lyx unterstützt derzeit keine Generics/Templates (vgl. Risikotabelle). Das WP kann nicht umgesetzt werden, bis Generics implementiert sind. Als Übergangslösung wird in WP 4b ein Makro-basiertes Fallback beschrieben.

#### WP 4a – Zielkonzept (Generics erforderlich)

```lyx
// Typgebundene Pins – der Compiler prüft die korrekte Verwendung
type
    PinId   = range 0..53;     // Nur gültige Pin-Nummern
    ModePin = generic<id: PinId, M: PinMode>;

    // Output-Pin: Schreiben erlaubt, Lesen verboten
    OutputPin = record[ModePin<id, Output>]
        procedure Write(state: PinState);
        // Read() existiert nicht → Compiler-Fehler bei Aufruf
    end;

    // Input-Pin: Lesen erlaubt, Schreiben verboten
    InputPin = record[ModePin<id, Input>]
        function Read(): PinState;
        // Write() existiert nicht → Compiler-Fehler bei Aufruf
    end;

var
    StatusLED: OutputPin<18>;  // Pin 18 als Ausgang
    Button:    InputPin<23>;   // Pin 23 als Eingang

begin
    StatusLED.Write(High);    // OK
    // StatusLED.Read();      // Compiler-Fehler
    // Button.Write(High);    // Compiler-Fehler
    Button.Read();            // OK
end.
```

**Weitere Prüfideen:**
- **Kurzschlusserkennung:** Der Compiler warnt, wenn zwei `OutputPin`-Instanzen auf denselben Pin-Nummern deklariert werden.
- **Modus-Konflikt:** Eine Variable kann nicht gleichzeitig `OutputPin<18>` und `InputPin<18>` sein.
- **Konfigurationsprüfung:** Der Compiler stellt sicher, dass `SetPullMode` nur für `InputPin` aufgerufen wird.

#### WP 4b – Makro-Fallback (ohne Generics)

Bis Generics verfügbar sind, kann ein Code-Generierungs-Makro die wichtigsten Sicherheitseigenschaften nachbilden:

```lyx
// Erzeuge typsichere Wrapper zur Compile-Zeit per Makro
macro DefineOutputPin(Name, PinNr)
begin
    procedure Name##_Write(state: PinState) = WritePin(PinNr, state);
    // kein Name##_Read → Linker-Fehler bei Aufruf
end;

macro DefineInputPin(Name, PinNr)
begin
    function Name##_Read(): Nullable<PinState> = ReadPin(PinNr);
    // kein Name##_Write → Linker-Fehler bei Aufruf
end;

DefineOutputPin(StatusLED, 18);
DefineInputPin(Button, 23);
```

> Diese Variante liefert nur Linker-Fehler statt Compiler-Fehler. Der Schutz ist geringer, aber besser als keiner.

#### Abnahmekriterien (WP 4a – nach Generics-Implementierung)
1. `OutputPin<18>.Write(High)` wird kompiliert; `OutputPin<18>.Read()` erzeugt einen Compiler-Fehler.
2. `InputPin<23>.Read()` wird kompiliert; `InputPin<23>.Write(High)` erzeugt einen Compiler-Fehler.
3. Zwei `OutputPin<18>`-Deklarationen in derselben Unit erzeugen mindestens eine Warning.
4. Der Compiler erzeugt für die typsicheren Aufrufe den identischen Maschinencode wie die manuelle Variante (Zero-Cost-Abstraktion).

---

### WP 5: Erweiterungen (Alternativfunktionen, Interrupts, PWM)

#### WP 5.1: Alternativfunktionen (Alt0–Alt5)

##### Info
GPIO-Pins können auch als I²C, SPI, UART, PCM etc. genutzt werden. Dazu muss `SetPinMode` um die Modi `Alt0`–`Alt5` erweitert werden:

```lyx
type
    PinMode = enum (Input, Output, Alt0, Alt1, Alt2, Alt3, Alt4, Alt5);
```

Die 3-Bit-Codes im FSEL-Register lauten:
| Modus | Code |
|-------|------|
| Input | `000` |
| Output | `001` |
| Alt0 | `100` |
| Alt1 | `101` |
| Alt2 | `110` |
| Alt3 | `111` |
| Alt4 | `011` |
| Alt5 | `010` |

> **Hinweis:** Die Codes sind **nicht** linear und unterscheiden sich zwischen BCM2835/BCM2711. Siehe Datenblatt.

##### Grund
Ohne Alternativfunktionen können die seriellen Schnittstellen (UART, I²C, SPI) nicht genutzt werden. Das ist für viele Embedded-Anwendungen essenziell.

##### Abnahmekriterien
1. `SetPinMode(2, Alt0)` konfiguriert Pin 2 als SDA1 (I²C).
2. Ein angeschlossener I²C-Sensor antwortet auf dem Bus.

---

#### WP 5.2: Interrupt-Unterstützung (Edge-Detection)

##### Info
Über die ioctl-Variante (WP 3) können Pins mit `GPIO_V2_LINE_FLAG_EDGE_RISING`, `_EDGE_FALLING` oder `_EDGE_BOTH` konfiguriert werden. Mit `sys_poll` kann das Programm dann blockieren, bis ein Ereignis eintritt:

```lyx
function WaitForEdge(line_fd: Int; timeout_ms: Int): Boolean;
var
    fds: PollFd;
    ret: Int;
begin
    fds.fd      := line_fd;
    fds.events  := POLLIN;
    fds.revents := 0;

    ret := sys_poll(addr(fds), 1, timeout_ms);
    return (ret > 0);
end;
```

##### Grund
Polling (aktives Warten in einer Schleife) blockiert die CPU zu 100 %. Mit Interrupts via `poll()` kann die CPU in einen Niedrigenergie-Zustand wechseln oder andere Aufgaben bearbeiten.

##### Abnahmekriterien
1. Ein Taster an Pin 23 (mit Edge-Rising) löst `WaitForEdge` innerhalb von 1 ms aus.
2. Ohne Tasterdruck läuft der Timeout korrekt ab.
3. Die CPU-Last im Wartezustand ist < 1 %.

---

#### WP 5.3: Software-PWM

##### Info
Da Variante A (MMIO) keinen Context-Switch benötigt, eignet sie sich für **Bit-Bang-PWM** in einer Echtzeit-Schleife:

```lyx
// frequency: Frequenz in Hz (1..100_000)
// dutyCycle: Tastverhältnis in Prozent (0..100)
// duration_ms: Gesamtdauer in Millisekunden
procedure SoftPWM(pin: Byte; frequency: DWord; dutyCycle: Byte; duration_ms: DWord);
var
    period_us:  DWord;
    high_us:    DWord;
    low_us:     DWord;
    elapsed_us: DWord;  // Zähler in Mikrosekunden – vermeidet Integer-Division auf 0
begin
    if frequency = 0 then return;

    period_us  := 1_000_000 / frequency;
    high_us    := (period_us * dutyCycle) / 100;
    low_us     := period_us - high_us;
    elapsed_us := 0;   // explizite Initialisierung

    while elapsed_us < (duration_ms * 1000) do
    begin
        WritePin(pin, High);
        DelayMicroseconds(high_us);
        WritePin(pin, Low);
        DelayMicroseconds(low_us);
        elapsed_us := elapsed_us + period_us; // immer >= 1 bei gültigem frequency
    end;
end;
```

> **Bug-Fix gegenüber v1:** In der Vorversion wurde `elapsed_ms + (period_us / 1000)` verwendet. Bei `frequency > 1000 Hz` ergibt `period_us / 1000 = 0` (Ganzzahldivision), was zu einer **Endlosschleife** führte. Die neue Variante zählt in Mikrosekunden und vergleicht gegen `duration_ms * 1000`.

> **Hinweis:** SoftPWM blockiert die CPU vollständig. Für mehrere PWM-Kanäle oder Frequenzen > 10 kHz ist ein DMA-gestützter Ansatz oder ein Hardware-PWM-Block nötig.

##### Grund
Viele Anwendungen benötigen PWM (LED-Dimmung, Motorsteuerung, Servos). Nicht alle Zielplattformen haben Hardware-PWM; Software-PWM ist der universelle Fallback.

##### Abnahmekriterien
1. LED an Pin 18 dimmt sichtbar mit 50 % DutyCycle bei 1 kHz.
2. Die Frequenz weicht um maximal 5 % vom Sollwert ab (gemessen mit Oszilloskop).
3. Die Funktion kehrt nach `duration_ms` Millisekunden zurück.
4. Kein Endlosschleifen-Verhalten bei `frequency > 1000 Hz`.
5. `SoftPWM(pin, 0, 50, 1000)` kehrt sofort zurück (Guard gegen Division durch Null).

---

## 4. Thread-Safety

Das MMIO-Modul (Variante A) verwendet **globale Variablen** (`gpio_mem`, `is_mapped`). Das führt zu Race-Conditions, wenn mehrere Threads gleichzeitig:

- `InitGPIO` und `CloseGPIO` aufrufen,
- denselben Pin über `SetPinMode` konfigurieren,
- `WritePin` und `ReadPin` auf demselben Pin-Bereich gleichzeitig aufrufen.

**Empfehlungen:**

| Szenario | Maßnahme |
|----------|----------|
| Single-threaded Anwendung | Keine Maßnahmen nötig |
| Init/Close aus mehreren Threads | Mutex um `InitGPIO`/`CloseGPIO` |
| Gleichzeitige Schreibzugriffe auf verschiedene Pins | Unkritisch (GPSET/GPCLR sind atomare Write-1-to-set-Register) |
| Gleichzeitige Schreibzugriffe auf denselben FSEL-Bereich | Kritisch: RMW-Zugriff auf FSEL ist nicht atomar – Mutex pro Register |

> Für die erste Implementierung wird **Single-Thread** vorausgesetzt. Thread-Safety kann als WP 6 nachgezogen werden.

---

## 5. Abhängigkeiten zwischen den Arbeitspaketen

```
WP 1 (Syscalls + Intrinsics)
  ├── WP 2.0 (Memory Barriers)
  │    └── WP 2 (MMIO)
  │         ├── WP 2.1 (Adressen)
  │         ├── WP 2.2 (Init/Close)
  │         ├── WP 2.3 (SetPinMode)
  │         ├── WP 2.4 (Write/Read)
  │         └── WP 2.5 (Pull-Up/Down)
  └── WP 3.0 (Hilfsfunktionen: CopyStringToBuf, DelayMicroseconds)
       └── WP 3 (ioctl)
            ├── WP 3.1 (Strukturen)
            ├── WP 3.2 (Chip-Info)
            └── WP 3.3 (Line-Request)

WP 4a (Typsicherheit) ─── GEBLOCKT bis Generics implementiert sind
WP 4b (Makro-Fallback) ── setzt WP 2.3 / WP 2.4 voraus

WP 5 (Erweiterungen)
  ├── WP 5.1 (Alt-Funktionen) ─────── setzt WP 2.3 voraus
  ├── WP 5.2 (Interrupts) ──────────── setzt WP 3.3 voraus
  └── WP 5.3 (SoftPWM) ───────────── setzt WP 2.4 + WP 3.0 voraus
```

**Empfohlene Reihenfolge:**
1. WP 1 (Grundlage: Syscalls + Barriere-Intrinsics)
2. WP 2.0 (Memory-Barrier-Konzept verankern)
3. WP 3.0 (Hilfsfunktionen, parallel zu WP 2.0 möglich)
4. WP 2.1 + WP 2.2 (Basis-MMIO)
5. WP 2.3 + WP 2.4 (Kernfunktion)
6. WP 3.1 + WP 3.2 + WP 3.3 (ioctl-Alternative)
7. WP 4b (Makro-Typsicherheit, parallel zu WP 5 möglich)
8. WP 5.1 + WP 5.2 + WP 5.3 (Erweiterungen, parallel zueinander)

---

## 6. Risiken und offene Fragen

| Risiko | Auswirkung | Maßnahme |
|--------|-----------|----------|
| `mmap`-Zugriff wird von `SELinux`/`AppArmor` blockiert | Variante A funktioniert nicht | Fallback auf ioctl (Variante B) |
| Unterschiedliche Pull-Register-Formate (BCM2711 Rev < 1.2 vs. ≥ 1.2) | Pull-Widerstände funktionieren nicht | Compile-Zeit-Konstante `HAS_NEW_PULL_REGS`; Legacy-Protokoll in WP 2.5 implementiert |
| IOCTL-Codes variieren zwischen Kernel-Versionen (< 5.10 hat keine v2-API) | ioctl-Aufrufe schlagen stumm fehl | Buildzeit-Vergleich gegen `/usr/include/linux/gpio.h`; bei v1-Kernel: Fallback auf v1-API |
| Lyx unterstützt (noch) keine Generics/Templates | WP 4a ist nicht umsetzbar | Makro-Fallback (WP 4b) als Übergang |
| MMIO-Schreibvorgänge werden durch CPU umgeordnet (ARM64 Out-of-Order) | Sporadische GPIO-Fehlzustände, schwer reproduzierbar | `mem_barrier()` nach jedem Register-Schreibzugriff (in WP 2.0/2.3/2.4/2.5 verankert) |
| Kein Thread-Safety | Race-Conditions bei Multi-Thread-Nutzung | Single-Thread-Scope für v1; Thread-Safety als separates WP 6 |
| `DelayMicroseconds` ungenau bei hoher Systemlast | SoftPWM-Frequenz weicht ab | Dokumentierte ±1-µs-Toleranz; CNTPCT_EL0-basierter Ansatz ist CPU-lastunabhängig |

---

## 7. Zusammenfassung

Das überarbeitete Dokument beschreibt einen **vollständigen Fahrplan** zur GPIO-Anbindung in Lyx:

| Arbeitspaket | Status (geplant) | Lieferumfang |
|-------------|------------------|--------------|
| **WP 1** Low-Level-Syscalls & Intrinsics | 🔜 | 7 ARM64-Syscall-Intrinsics + `mem_barrier`/`inst_barrier` |
| **WP 2.0** Memory Barriers | 🔜 | Konzept + Barriere-Regeln für MMIO |
| **WP 2** MMIO-Variante | 🔜 | Init/Close/SetPinMode/WritePin/ReadPin/SetPullMode (mit Barrieren) |
| **WP 3.0** Hilfsfunktionen | 🔜 | CopyStringToBuf, DelayMicroseconds |
| **WP 3** ioctl-Variante | 🔜 | Chip-Info, Line-Request, Get/Set-Values |
| **WP 4a** Typsicherheit (Generics) | 🔴 Geblockt | OutputPin/InputPin mit Compiler-Garantien |
| **WP 4b** Typsicherheit (Makros) | 🔜 | Makro-basierter Typ-Schutz als Übergangslösung |
| **WP 5** Erweiterungen | 🔜 | Alt-Funktionen, Interrupts, Software-PWM (Bug-fixed) |

Jedes Arbeitspaket enthält prüfbare **Abnahmekriterien**, sodass der Fortschritt objektiv messbar ist.

---

*Stand: Mai 2026 – Überarbeitete Fassung v2 auf Basis des Code-Reviews*
