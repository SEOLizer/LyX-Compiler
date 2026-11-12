/*
 * tests/lib/rv_solader.c — laedt eine riscv64-.so von lyxc und ruft ihre
 * Exporte als C-Funktionen (#2162).
 *
 * Ohne riscv-glibc-Sysroot gibt es kein dlopen fuer das Ziel; dieses
 * Programm (mit dem NDK statisch gegen bionic gebaut, laeuft unter
 * qemu-user) uebernimmt dessen Teil:
 *
 *   - PT_LOAD an eine feste Basis legen (ET_DYN, st_value relativ dazu),
 *   - R_RISCV_64 auf UNDEF-Symbole ueber den Namen auf Funktionen DIESES
 *     Programms setzen (pow aus libm),
 *   - Exporte ueber DT_HASH suchen — wie dlsym; ein falscher Hash fiele hier
 *     als "Symbol fehlt" auf, nicht erst auf dem Geraet,
 *   - die Funktionen mit ihrem C-Typ rufen (clang legt Gleitkomma nach LP64D
 *     in fa-Register, Ergebnis aus fa0),
 *   - einen Export mit Merkwerten in s1..s11 rufen und danach vergleichen.
 *
 * Ausgabe: eine Zeile mit den Ergebnissen; rc 97 = Symbol fehlt.
 */
#include <elf.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* rufe(fn, merk, nachher, dbits): s1..s11 := merk+1..merk+11, fa0 := dbits,
 * fn() rufen, die s-Register danach in nachher[0..10]; Rueckgabe = a0. */
long rufe(long fn, long merk, long *nachher, long dbits);
__asm__(
    ".text\n.globl rufe\nrufe:\n"
    "  addi sp, sp, -112\n"
    "  sd ra, 0(sp)\n  sd s0, 8(sp)\n  sd s1, 16(sp)\n  sd s2, 24(sp)\n"
    "  sd s3, 32(sp)\n  sd s4, 40(sp)\n  sd s5, 48(sp)\n  sd s6, 56(sp)\n"
    "  sd s7, 64(sp)\n  sd s8, 72(sp)\n  sd s9, 80(sp)\n  sd s10, 88(sp)\n"
    "  sd s11, 96(sp)\n  sd a2, 104(sp)\n"
    "  addi s1, a1, 1\n  addi s2, a1, 2\n  addi s3, a1, 3\n  addi s4, a1, 4\n"
    "  addi s5, a1, 5\n  addi s6, a1, 6\n  addi s7, a1, 7\n  addi s8, a1, 8\n"
    "  addi s9, a1, 9\n  addi s10, a1, 10\n  addi s11, a1, 11\n"
    "  fmv.d.x fa0, a3\n"
    "  mv t1, a0\n"
    "  jalr ra, 0(t1)\n"
    "  ld t0, 104(sp)\n"
    "  sd s1, 0(t0)\n  sd s2, 8(t0)\n  sd s3, 16(t0)\n  sd s4, 24(t0)\n"
    "  sd s5, 32(t0)\n  sd s6, 40(t0)\n  sd s7, 48(t0)\n  sd s8, 56(t0)\n"
    "  sd s9, 64(t0)\n  sd s10, 72(t0)\n  sd s11, 80(t0)\n"
    "  ld ra, 0(sp)\n  ld s0, 8(sp)\n  ld s1, 16(sp)\n  ld s2, 24(sp)\n"
    "  ld s3, 32(sp)\n  ld s4, 40(sp)\n  ld s5, 48(sp)\n  ld s6, 56(sp)\n"
    "  ld s7, 64(sp)\n  ld s8, 72(sp)\n  ld s9, 80(sp)\n  ld s10, 88(sp)\n"
    "  ld s11, 96(sp)\n"
    "  addi sp, sp, 112\n  ret\n");

static unsigned long elf_hash(const char *n) {
  unsigned long h = 0, g;
  while (*n) {
    h = (h << 4) + (unsigned char)*n++;
    g = h & 0xF0000000UL;
    if (g) h ^= g >> 24;
    h &= ~g;
  }
  return h;
}

static uint64_t basis;
static Elf64_Sym *symtab;
static const char *strtab;
static uint32_t *hashtab;

static void *suche(const char *name) {
  uint32_t nb = hashtab[0];
  uint32_t *bucket = hashtab + 2, *chain = bucket + nb;
  for (uint32_t i = bucket[elf_hash(name) % nb]; i; i = chain[i])
    if (symtab[i].st_shndx != SHN_UNDEF && strcmp(strtab + symtab[i].st_name, name) == 0)
      return (void *)(basis + symtab[i].st_value);
  fprintf(stderr, "Symbol fehlt: %s\n", name);
  exit(97);
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "rv_solader <bibliothek>\n"); return 96; }
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) { perror("open"); return 96; }
  off_t len = lseek(fd, 0, SEEK_END);
  unsigned char *f = malloc(len);
  if (pread(fd, f, len, 0) != len) { perror("read"); return 96; }
  close(fd);
  Elf64_Ehdr *eh = (Elf64_Ehdr *)f;
  if (memcmp(eh->e_ident, ELFMAG, 4) != 0 || eh->e_machine != EM_RISCV || eh->e_type != ET_DYN) {
    fprintf(stderr, "keine riscv-.so (ET_DYN)\n"); return 96;
  }
  basis = 0x20000000;
  Elf64_Phdr *ph = (Elf64_Phdr *)(f + eh->e_phoff);
  Elf64_Dyn *dyn = 0;
  for (int i = 0; i < eh->e_phnum; i++) {
    if (ph[i].p_type == PT_LOAD) {
      uint64_t lo = (basis + ph[i].p_vaddr) & ~0xFFFULL;
      uint64_t hi = (basis + ph[i].p_vaddr + ph[i].p_memsz + 0xFFF) & ~0xFFFULL;
      void *m = mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
      if (m != (void *)lo) { perror("mmap"); return 96; }
      memcpy((void *)(basis + ph[i].p_vaddr), f + ph[i].p_offset, ph[i].p_filesz);
    }
    if (ph[i].p_type == PT_DYNAMIC) dyn = (Elf64_Dyn *)(basis + ph[i].p_vaddr);
  }
  if (!dyn) { fprintf(stderr, "kein PT_DYNAMIC\n"); return 96; }
  Elf64_Rela *rela = 0; uint64_t relasz = 0;
  for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
    if (d->d_tag == DT_RELA) rela = (Elf64_Rela *)(basis + d->d_un.d_ptr);
    if (d->d_tag == DT_RELASZ) relasz = d->d_un.d_val;
    if (d->d_tag == DT_SYMTAB) symtab = (Elf64_Sym *)(basis + d->d_un.d_ptr);
    if (d->d_tag == DT_STRTAB) strtab = (const char *)(basis + d->d_un.d_ptr);
    if (d->d_tag == DT_HASH) hashtab = (uint32_t *)(basis + d->d_un.d_ptr);
  }
  if (!symtab || !strtab || !hashtab) { fprintf(stderr, "Tabellen fehlen\n"); return 96; }
  for (uint64_t k = 0; rela && k < relasz / sizeof(Elf64_Rela); k++) {
    uint32_t typ = ELF64_R_TYPE(rela[k].r_info);
    const char *nm = strtab + symtab[ELF64_R_SYM(rela[k].r_info)].st_name;
    if (typ != 2 /* R_RISCV_64 */) { fprintf(stderr, "Relocation-Typ %u\n", typ); return 98; }
    void *a = 0;
    if (strcmp(nm, "pow") == 0) a = (void *)pow;
    if (!a) { fprintf(stderr, "unbekanntes Symbol: %s\n", nm); return 97; }
    *(uint64_t *)(basis + rela[k].r_offset) = (uint64_t)a + rela[k].r_addend;
  }

  double (*rechne)(double, long) = suche("rechne");
  double (*mischen)(long, float, double, long) = suche("mischen");
  long (*ganz)(long, long) = suche("ganz");
  float (*viertel)(float) = suche("viertel");
  double (*kubik)(double) = suche("kubik");
  long fmt = (long)suche("fmt");
  printf("%.1f %.2f %ld %.2f %.1f", rechne(1.5, 3), mischen(4, 0.5f, 10.25, 2),
         ganz(4, 2), viertel(5.0f), kubik(2.0));
  long nachher[11], merk = 0x5100;
  double x = 2.5; long xb; memcpy(&xb, &x, 8);
  long r = rufe(fmt, merk, nachher, xb);
  printf(" fmt=%ld verloren=", r);
  int n = 0;
  for (int i = 0; i < 11; i++)
    if (nachher[i] != merk + i + 1) { printf("%ss%d", n ? "," : "", i + 1); n++; }
  if (!n) printf("-");
  printf("\n");
  return 0;
}
