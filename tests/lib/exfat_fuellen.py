#!/usr/bin/env python3
"""tests/lib/exfat_fuellen.py — legt Dateien und Verzeichnisse in ein exFAT-Abbild.

WARUM ES DIESES SKRIPT GIBT: fuer FAT gibt es `mtools` (mcopy/mmd), fuer exFAT
nicht — und ein Loop-Mount braucht Wurzelrechte. Ohne dieses Skript liesse
sich nur ein LEERES Abbild pruefen.

WARUM DAS TROTZDEM TRAEGT: der Richter ist nicht dieses Skript, sondern
`fsck.exfat` aus exfatprogs. Der Testlauf schreibt das Abbild, laesst es von
fsck pruefen und liest es erst dann mit std.fs.exfat. Waere hier etwas falsch,
meldete fsck es — eine fremde Umsetzung, die dieselbe Spezifikation gelesen
hat.

Absichtlich ungleich angelegt:
  * eine kleine Datei zusammenhaengend (NoFatChain)
  * eine grosse Datei FRAGMENTIERT mit echter FAT-Kette — sonst wuerde die
    Kettenverfolgung nie geprueft, weil exFAT zusammenhaengende Dateien ohne
    FAT ablegt
  * ein Verzeichnis mit Unterverzeichnis
  * ein langer Name, der mehrere Namenseintraege braucht
"""
import struct, sys

class ExFat:
    def __init__(self, pfad):
        self.f = open(pfad, "r+b")
        bs = self.f.read(512)
        if bs[3:11] != b"EXFAT   ":
            raise SystemExit("kein exFAT-Abbild")
        self.fat_off, self.fat_len, self.heap_off, self.clus_cnt, self.root = \
            struct.unpack_from("<IIIII", bs, 80)
        self.bps = 1 << bs[108]
        self.spc = 1 << bs[109]
        self.cluster_bytes = self.bps * self.spc
        self.bitmap_clus = None
        self.bitmap_len = 0
        self._lies_bitmap()

    # ---- Grundzugriffe ----
    def clus_pos(self, c):
        return (self.heap_off + (c - 2) * self.spc) * self.bps

    def lies_cluster(self, c):
        self.f.seek(self.clus_pos(c)); return bytearray(self.f.read(self.cluster_bytes))

    def schreib_cluster(self, c, daten):
        self.f.seek(self.clus_pos(c)); self.f.write(bytes(daten))

    def fat_setz(self, c, wert):
        self.f.seek(self.fat_off * self.bps + c * 4)
        self.f.write(struct.pack("<I", wert & 0xFFFFFFFF))

    # ---- Belegungsbitmap ----
    def _lies_bitmap(self):
        root = self.lies_cluster(self.root)
        for i in range(0, self.cluster_bytes, 32):
            if root[i] == 0x81:
                self.bitmap_clus, self.bitmap_len = struct.unpack_from("<IQ", root, i + 20)
                return
        raise SystemExit("Belegungsbitmap nicht gefunden")

    def _bitmap_pos(self, c):
        bit = c - 2
        return self.clus_pos(self.bitmap_clus) + bit // 8, 1 << (bit % 8)

    def belegt(self, c):
        pos, maske = self._bitmap_pos(c)
        self.f.seek(pos); return (self.f.read(1)[0] & maske) != 0

    def belege(self, c):
        pos, maske = self._bitmap_pos(c)
        self.f.seek(pos); b = self.f.read(1)[0]
        self.f.seek(pos); self.f.write(bytes([b | maske]))

    def freie_cluster(self, n, luecke=0):
        """n freie Cluster. `luecke` ueberspringt jeweils so viele — damit
        entsteht eine FRAGMENTIERTE Datei mit echter FAT-Kette."""
        gefunden, c = [], 2
        while len(gefunden) < n and c < self.clus_cnt + 2:
            if not self.belegt(c):
                gefunden.append(c)
                c += 1 + luecke
            else:
                c += 1
        if len(gefunden) < n:
            raise SystemExit("zu wenig freie Cluster")
        return gefunden

    # ---- Datenstroeme ----
    def schreib_strom(self, daten, luecke=0):
        """Gibt (erster_cluster, no_fat_chain) zurueck."""
        n = max(1, (len(daten) + self.cluster_bytes - 1) // self.cluster_bytes)
        cl = self.freie_cluster(n, luecke)
        for c in cl:
            self.belege(c)
        for i, c in enumerate(cl):
            teil = daten[i * self.cluster_bytes:(i + 1) * self.cluster_bytes]
            teil = teil + bytes(self.cluster_bytes - len(teil))
            self.schreib_cluster(c, teil)
        zusammen = all(cl[i] + 1 == cl[i + 1] for i in range(len(cl) - 1))
        if zusammen:
            # NoFatChain: die FAT bleibt fuer diesen Strom unbeschrieben.
            return cl[0], True
        for i, c in enumerate(cl):
            self.fat_setz(c, 0xFFFFFFFF if i == len(cl) - 1 else cl[i + 1])
        return cl[0], False

    # ---- Verzeichniseintraege ----
    @staticmethod
    def _namenshash(name):
        h = 0
        for ch in name.upper():
            b = ch.encode("utf-16-le")
            for x in b:
                h = (((h & 1) << 15) | (h >> 1)) + x & 0xFFFF
        return h

    @staticmethod
    def _satzpruefsumme(eintraege):
        roh = b"".join(eintraege)
        s = 0
        for i, x in enumerate(roh):
            if i == 2 or i == 3:
                continue
            s = (((s & 1) << 15) | (s >> 1)) + x & 0xFFFF
        return s

    def baue_satz(self, name, erster_cluster, laenge, ist_dir, no_fat_chain):
        nutz = name.encode("utf-16-le")
        n_namens = (len(name) + 14) // 15

        datei = bytearray(32)
        datei[0] = 0x85
        datei[1] = 1 + n_namens
        struct.pack_into("<H", datei, 4, 0x10 if ist_dir else 0x20)
        struct.pack_into("<I", datei, 8, 0x50000000)    # Erstellzeit, irgendein gueltiger Wert
        struct.pack_into("<I", datei, 12, 0x50000000)
        struct.pack_into("<I", datei, 16, 0x50000000)

        strom = bytearray(32)
        strom[0] = 0xC0
        strom[1] = 0x01 | (0x02 if no_fat_chain else 0x00)   # AllocationPossible [+ NoFatChain]
        strom[3] = len(name)
        struct.pack_into("<H", strom, 4, self._namenshash(name))
        struct.pack_into("<Q", strom, 8, laenge)             # ValidDataLength
        struct.pack_into("<I", strom, 20, erster_cluster)
        struct.pack_into("<Q", strom, 24, laenge)            # DataLength

        namens = []
        for i in range(n_namens):
            e = bytearray(32)
            e[0] = 0xC1
            teil = nutz[i * 30:(i + 1) * 30]
            e[2:2 + len(teil)] = teil
            namens.append(bytes(e))

        alle = [bytes(datei), bytes(strom)] + namens
        struct.pack_into("<H", datei, 2, self._satzpruefsumme(alle))
        return b"".join([bytes(datei), bytes(strom)] + namens)

    def haenge_an(self, dir_cluster, satz):
        """Eintragssatz an das Ende eines Verzeichnisses setzen."""
        c = dir_cluster
        daten = self.lies_cluster(c)
        pos = 0
        while pos < len(daten) and daten[pos] != 0x00:
            pos += 32
        if pos + len(satz) + 32 > len(daten):
            raise SystemExit("Verzeichniscluster voll — der Test braucht keine zweite Stufe")
        daten[pos:pos + len(satz)] = satz
        self.schreib_cluster(c, daten)

    def neues_verzeichnis(self, eltern_cluster, name):
        c, kette = self.schreib_strom(bytes(self.cluster_bytes))
        self.haenge_an(eltern_cluster, self.baue_satz(name, c, self.cluster_bytes, True, kette))
        return c

    def neue_datei(self, dir_cluster, name, daten, luecke=0):
        c, kette = self.schreib_strom(daten, luecke)
        self.haenge_an(dir_cluster, self.baue_satz(name, c, len(daten), False, kette))

    def prozent_setzen(self):
        # PercentInUse auf 0xFF (unbekannt) — fsck nimmt das an und rechnet
        # nicht dagegen. Eine falsche Zahl waere schlimmer als keine.
        self.f.seek(112); self.f.write(bytes([0xFF]))

    def schliessen(self):
        self.f.flush(); self.f.close()


def main():
    v = ExFat(sys.argv[1])
    klein = b"Hallo exFAT\n"
    gross = bytes((i * 7 + 3) & 255 for i in range(200000))

    v.neue_datei(v.root, "HALLO.TXT", klein)
    # Luecke 1: jeder zweite Cluster — erzwingt eine echte FAT-Kette.
    v.neue_datei(v.root, "GROSS.BIN", gross, luecke=1)
    v.neue_datei(v.root, "Ein langer Dateiname.txt", klein)

    ordner = v.neues_verzeichnis(v.root, "ORDNER")
    tief = v.neues_verzeichnis(ordner, "TIEF")
    v.neue_datei(tief, "UNTEN.TXT", klein)

    v.prozent_setzen()
    v.schliessen()


if __name__ == "__main__":
    main()
