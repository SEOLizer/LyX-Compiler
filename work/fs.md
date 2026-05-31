# std/fs — Erweiterungsplan

**Datei:** `std/fs.lyx` · **Konvention:** WP-FS-NN · **Status:** ✅ Erledigt · 🔄 In Arbeit · ⬜ Offen

---

## Ist-Zustand (Stand: 2026-05-31)

| Kategorie | Funktionen |
|-----------|-----------|
| Datei-I/O | `ReadFile`, `WriteFile`, `AppendFile`, `DeleteFile`, `FileSize` |
| Stdout/Stderr | `StdoutWrite`, `StderrWrite`, `PutChar` |
| Pfad-Manipulation | `PathNormalize`, `PathDir`, `PathExt`, `PathBase`, `PathResolve` |
| Verzeichnis-Listing | `DirList`, `DirEntryCount`, `DirEntryType`, `DirFree` |
| Hilfsfunktionen | `IsValidFd` |
| Konstanten | `O_*`, `S_I*`, `SEEK_*`, `DT_*`, `STDIN/OUT/ERR_FILENO` |

**Fehlend:** Type-Checks, Verzeichnis-Schreib-Ops, Metadaten (mtime, mode),
Symlink-Support, rekursive Operationen, automatisch allokierendes FileReadAll.

---

## WP-FS-01: File-Existence & Type-Checks ✅

**Ziel:** Die häufigsten Prüffragen „Existiert die Datei?", „Ist es ein Verzeichnis?"
direkt beantworten können.

**Braucht keine neuen Builtins** — `open`/`close` und `O_DIRECTORY` sind bereits
vorhanden.

**Zu implementieren:**

```
pub fn FileExists(path: pchar): bool
  // open(O_RDONLY) + close → true wenn fd >= 0

pub fn IsDirectory(path: pchar): bool
  // open(O_RDONLY | O_DIRECTORY) + close → true wenn fd >= 0

pub fn IsFile(path: pchar): bool
  // open(O_RDONLY) + versuch als Verzeichnis → true wenn kein O_DIRECTORY-fd möglich
  // Einfachste Variante: open ohne O_DIRECTORY → fd >= 0 && !IsDirectory
```

**Akzeptanzkriterien:**
- `FileExists("/tmp")` → true
- `FileExists("/tmp/nicht-vorhanden-xyz")` → false
- `IsDirectory("/tmp")` → true, `IsDirectory("/etc/hostname")` → false
- `IsFile("/etc/hostname")` → true, `IsFile("/tmp")` → false

---

## WP-FS-02: Verzeichnis-Schreib-Ops & Umbenennungen ✅

**Ziel:** Die bereits als Compiler-Builtins vorhandenen Syscalls
(`mkdir`, `rmdir`, `rename`, `chmod`) als saubere pub-Funktionen in `std/fs` anbieten.

**Alle Builtins bereits vorhanden** — nur Wrapper nötig.

**Zu implementieren:**

```
pub fn Mkdir(path: pchar, mode: int64): bool
  // return mkdir(path, mode) == 0

pub fn Rmdir(path: pchar): bool
  // return rmdir(path) == 0

pub fn Remove(path: pchar): bool
  // Datei oder leeres Verzeichnis löschen:
  // versucht unlink, bei EISDIR rmdir

pub fn Rename(oldPath: pchar, newPath: pchar): bool
  // return rename(oldPath, newPath) == 0

pub fn Chmod(path: pchar, mode: int64): bool
  // return chmod(path, mode) == 0

pub con S_IRWXU: int64 := 448;   // 0700
pub con S_IRWXG: int64 := 56;    // 0070
pub con S_IRWXO: int64 := 7;     // 0007
pub con DEFAULT_DIR_MODE: int64 := 493;  // 0755
```

**Akzeptanzkriterien:**
- `Mkdir("/tmp/lyx_test", DEFAULT_DIR_MODE)` → true, Verzeichnis existiert
- `Rename("/tmp/lyx_test", "/tmp/lyx_test2")` → true
- `Chmod("/tmp/lyx_test2", 448)` → true
- `Rmdir("/tmp/lyx_test2")` → true, Verzeichnis weg

---

## WP-FS-03: File-Utilities (Copy, Move, ReadAll) ✅

**Ziel:** Komfort-Operationen die auf bestehenden Primitiven aufbauen.

**Kein neuer Compiler-Aufwand.**

**Zu implementieren:**

```
pub fn FileCopy(src: pchar, dest: pchar): bool
  // open(src, O_RDONLY) → lseek(SEEK_END) für Größe → mmap → read → write → close
  // Gibt false zurück wenn src nicht lesbar oder dest nicht schreibbar

pub fn FileMove(src: pchar, dest: pchar): bool
  // Versucht Rename; bei EXDEV (anderes Dateisystem) → FileCopy + Remove

pub fn FileReadAll(path: pchar): pchar
  // Liest kompletten Dateiinhalt, null-terminiert
  // Allokiert via mmap — Aufrufer ruft FileReadFree(ptr, size) auf
  // Gibt 0 zurück bei Fehler

pub fn FileReadFree(ptr: pchar, size: int64): void
  // munmap(ptr, size)
```

**Hinweis zu FileReadAll:** Der Aufrufer muss die Größe kennen für das Freigeben.
Alternative: ersten 8 Bytes als Länge speichern (wie DirList) → `FileReadFree` ohne size-Arg.

**Akzeptanzkriterien:**
- `FileCopy("/etc/hostname", "/tmp/hostname_copy")` → Inhalt identisch
- `FileReadAll("/etc/hostname")` → korrekte Zeichenkette, null-terminiert
- `FileMove("/tmp/hostname_copy", "/tmp/hostname_moved")` → true

---

## WP-FS-04: Pfad-Utilities — PathJoin & IsAbsolutePath ✅

**Ziel:** Die zwei häufigsten Pfad-Operationen die aktuell fehlen.
`PathNormalize/Dir/Ext/Base/Resolve` sind vorhanden, aber Kombinieren und Prüfen fehlt.

**Pure Lyx, kein Compiler-Aufwand.**

**Zu implementieren:**

```
pub fn PathJoin(a: pchar, b: pchar): pchar
  // Verbindet zwei Pfad-Teile mit "/" wenn nötig
  // PathJoin("/home/user", "docs") → "/home/user/docs"
  // PathJoin("/home/user/", "docs") → "/home/user/docs"
  // PathJoin("", "docs") → "docs"
  // Allokiert via mmap, Aufrufer ist verantwortlich

pub fn IsAbsolutePath(path: pchar): bool
  // return peek8(path) == 47  // '/'
```

**Akzeptanzkriterien:**
- `PathJoin("/home/user", "docs/file.txt")` → `"/home/user/docs/file.txt"`
- `PathJoin("/home/user/", "docs")` → `"/home/user/docs"`
- `IsAbsolutePath("/etc/hosts")` → true
- `IsAbsolutePath("relative/path")` → false

---

## WP-FS-05: Stat — Datei-Metadaten ✅

**Ziel:** Änderungszeit, Zugriffszeit, Dateigröße und Berechtigungen aus einem
einzigen Syscall lesen (`stat`). Aktuell verwendet `FileSize` einen `lseek`-Umweg;
`stat` ist schneller und liefert mehr Informationen.

**Braucht neuen Compiler-Builtin:** `stat` (Syscall 4) und `lstat` (Syscall 6).

**struct stat Layout (x86_64 Linux, 144 Bytes):**
```
+0:   dev_t     st_dev      (8 Bytes)
+8:   ino_t     st_ino      (8)
+16:  nlink_t   st_nlink    (8)
+24:  mode_t    st_mode     (4)  ← Dateityp + Berechtigungen
+28:  uid_t     st_uid      (4)
+32:  gid_t     st_gid      (4)
+36:  (pad)                 (4)
+40:  dev_t     st_rdev     (8)
+48:  off_t     st_size     (8)  ← Dateigröße
+56:  blksize_t st_blksize  (8)
+64:  blkcnt_t  st_blocks   (8)
+72:  time_t    st_atime    (8)  ← Letzter Zugriff
+80:  time_t    st_mtime    (8)  ← Letzte Änderung
+88:  time_t    st_ctime    (8)  ← Letzte Status-Änderung
```

**Compiler-Änderungen (codegen_x86.lyx + sema.lyx):**
```
// stat(path, buf): syscall 4
self.cg_seq(fname, fnlen, "stat", 4) → cg_movRaxImm(4); syscall

// lstat(path, buf): syscall 6
self.cg_seq(fname, fnlen, "lstat", 6) → cg_movRaxImm(6); syscall
```

**Zu implementieren (std/fs.lyx):**
```
pub fn FileStat(path: pchar, statBuf: int64): bool
  // Direkt-Wrapper: return stat(path, statBuf) == 0

pub fn FileModTime(path: pchar): int64
  // mmap(144) + stat → peek64(+80) + munmap

pub fn FileAccessTime(path: pchar): int64
  // mmap(144) + stat → peek64(+72) + munmap

pub fn FileSizeFast(path: pchar): int64
  // mmap(144) + stat → peek64(+48) + munmap  (kein fd nötig)

pub fn FilePerm(path: pchar): int64
  // mmap(144) + stat → peek32(+24) & 0x1FF + munmap  (Berechtigungsbits)

pub fn IsLink(path: pchar): bool
  // mmap(144) + lstat → mode & S_IFMT == S_IFLNK + munmap
  // S_IFLNK = 0xa000 = 40960, S_IFMT = 0xf000 = 61440
```

**Akzeptanzkriterien:**
- `FileModTime("/etc/hostname")` → Unix-Timestamp > 0
- `FileSizefast("/etc/hostname")` stimmt mit Dateigröße überein
- `FilePerm("/etc/hostname")` → 0644 (420 decimal)
- `IsLink("/etc/localtime")` → true (Symlink auf Zeitzone)

---

## WP-FS-06: Symlinks — Symlink, ReadLink ✅

**Ziel:** Symbolische Links erstellen und auflesen.

**Braucht neue Compiler-Builtins:** `symlink` (Syscall 88), `readlink` (Syscall 89).

**Compiler-Änderungen:**
```
// symlink(target, linkpath): syscall 88
// readlink(path, buf, bufsize): syscall 89
```

**Zu implementieren:**
```
pub fn Symlink(target: pchar, linkPath: pchar): bool
  // return symlink(target, linkPath) == 0

pub fn ReadLink(path: pchar, buf: pchar, bufLen: int64): int64
  // return readlink(path, buf, bufLen)
  // Gibt Anzahl geschriebener Bytes zurück, -1 bei Fehler
  // Kein automatisches Null-Byte — Aufrufer muss poke8(buf + result, 0) setzen
```

**Akzeptanzkriterien:**
- `Symlink("/etc/hostname", "/tmp/hostname_link")` → true, Link existiert
- `IsLink("/tmp/hostname_link")` → true (braucht WP-FS-05)
- `ReadLink("/tmp/hostname_link", buf, 256)` → schreibt "/etc/hostname" in buf
- `unlink("/tmp/hostname_link")` entfernt Link ohne Target zu berühren

---

## WP-FS-07: MkdirAll — Rekursives Verzeichnis erstellen ✅

**Ziel:** `MkdirAll("/a/b/c/d", mode)` erstellt alle fehlenden Pfad-Komponenten,
analog zu `mkdir -p`. Häufig benötigt beim Aufbau von Verzeichnisstrukturen.

**Kein neuer Compiler-Aufwand** — baut auf `Mkdir` (WP-FS-02) und `IsDirectory` (WP-FS-01) auf.

**Algorithmus:**
```
MkdirAll(path, mode):
  if IsDirectory(path): return true
  // Finde letzten '/'
  parent := PathDir(buf, path)
  if parent != ".":
    MkdirAll(parent, mode)  // rekursiv
  return Mkdir(path, mode)
```

**Implementierungshinweis:** Lyx unterstützt keine echte Rekursion mit Stack-Allokation
für pchar-Puffer. Iterativer Ansatz mit Segment-Pointer bevorzugen:
Slash-Positionen durchiterieren, `poke8` zum temporären Null-Terminieren.

**Zu implementieren:**
```
pub fn MkdirAll(path: pchar, mode: int64): bool
```

**Akzeptanzkriterien:**
- `MkdirAll("/tmp/lyx_a/b/c/d", 493)` → true, alle 4 Ebenen angelegt
- Auf existierendem Pfad aufgerufen → true (kein Fehler)
- `MkdirAll("/tmp/lyx_a/b/c/d", 493)` zweimal → true (idempotent)

---

## WP-FS-08: DirWalk — Rekursive Verzeichnis-Traversal ⬜

**Ziel:** Ein komplettes Verzeichnis rekursiv durchlaufen. Grundlage für Tools wie
`find`, rekursives Kopieren, Datei-Suche.

**Baut auf WP-FS-01 (IsDirectory), WP-FS-04 (PathJoin) und DirList auf.**

**API-Design:** Da Lyx keine First-Class-Functions/Callbacks kennt, gibt
`DirWalk` einen Flat-Buffer mit allen gefundenen Pfaden zurück (ähnlich DirList):

```
pub fn DirWalk(root: pchar): int64
  // Gibt Buffer zurück mit:
  // [0..7]   count     int64
  // [8..15]  totalSize int64
  // [16..]   Einträge: pathLen(8) + type(1) + path(pathLen) + NUL
  //           path ist immer vollständiger absoluter Pfad

pub fn DirWalkCount(result: int64): int64
  // wie DirEntryCount

pub fn DirWalkPath(result: int64, index: int64, outBuf: pchar): int64
  // Schreibt Pfad des index-ten Eintrags nach outBuf, gibt Länge zurück

pub fn DirWalkType(result: int64, index: int64): int64
  // DT_* Typ des index-ten Eintrags

pub fn DirWalkFree(result: int64): void
  // munmap
```

**Implementierungshinweis:** Maximale Tiefe auf 32 Ebenen begrenzen (Stack-Schutz).
Buffer auf 4 MB begrenzen (ausreichend für die meisten Anwendungsfälle).

**Akzeptanzkriterien:**
- `DirWalk("/etc")` → alle Dateien rekursiv, keine Abstürze
- Ergebnis enthält vollständige Pfade wie `/etc/ssl/certs/ca.pem`
- Symlinks auf Verzeichnisse werden NICHT weiter verfolgt (verhindert Loops)

---

## Phasen-Übersicht

| Phase | WPs | Voraussetzungen | Compiler-Änderung |
|-------|-----|----------------|-------------------|
| 1 — Sofort | FS-01, FS-02, FS-03, FS-04 | Keine | Keine |
| 2 — Stat | FS-05 | Phase 1 | `stat`, `lstat` als Builtins |
| 3 — Symlinks | FS-06 | FS-05 (für IsLink) | `symlink`, `readlink` als Builtins |
| 4 — Rekursiv | FS-07, FS-08 | FS-01, FS-02, FS-04 | Keine |

**Phase 1** ist komplett ohne Compiler-Änderungen umsetzbar und deckt
den größten Teil des alltäglichen Bedarfs ab.

---

## Bereits erledigt

| WP | Feature | Branch/PR |
|----|---------|-----------|
| ✅ v0.3.0 | `open`/`read`/`write`/`close` als Compiler-Builtins | — |
| ✅ v0.3.1 | `mkdir`, `rmdir`, `unlink`, `rename`, `chmod` als Builtins | — |
| ✅ v0.3.2 | `DirList`, `DirEntryCount`, `DirEntryType`, `DirFree` (getdents64) | PR #565 |
