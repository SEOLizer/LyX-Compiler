/*
 * tests/lib/a64_binder.c — ein Binder fuer dynamisch gelinkte arm64-Erzeugnisse
 * von lyxc, damit ein FFI-Aufruf unter dem User-Mode-Emulator WIRKLICH eine
 * C-Funktion trifft (#2140).
 *
 * Auf dem Testrechner gibt es keinen aarch64-glibc-Sysroot und also kein
 * /lib/ld-linux-aarch64.so.1. Dieses Programm wird mit dem NDK statisch gegen
 * bionic gebaut (laeuft unter qemu-user) und uebernimmt die Rolle des
 * dynamischen Binders — genau die, die das Erzeugnis von ihm verlangt:
 *
 *   - PT_LOAD an seine feste Adresse legen (ET_EXEC, 0x400000),
 *   - jede R_AARCH64_GLOB_DAT / JUMP_SLOT / ABS64 ueber den Symbolnamen auf
 *     eine Funktion DIESES Programms setzen,
 *   - e_entry anspringen, mit einem Stapel wie vom Kern (argc, argv, envp).
 *
 * Die Gegenseite sind echte, von clang nach AAPCS64 uebersetzte Funktionen:
 * libm (pow, atan2, fabs, powf) und einige Testfunktionen, deren Ergebnis die
 * POSITION jedes Arguments erkennen laesst. Ein Wert in der falschen Reihe
 * (x statt d) liefert dort eine andere Zahl, nicht dieselbe.
 *
 * Ein unbekanntes Symbol ist rc 97, kein stilles 0.
 */
#include <elf.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>

/* --- Gegenseite: Funktionen mit erkennbarer Argumentlage -------------------- */

/* Ganzzahl und double abwechselnd: getrennte Reihen x0,x1 / d0,d1. */
double t_misch(long a, double x, long b, double y) {
  return (double)a * 1000.0 + x * 100.0 + (double)b * 10.0 + y;
}
/* float rein, float raus: s0, nicht d0. */
float t_halbf(float x) { return x / 2.0f; }
/* float und double gemischt. */
double t_fd(float a, double b) { return (double)a * 10.0 + b; }
/* int-Rueckgabe: clang schreibt nur w0. */
int t_minus_eins(void) { return -1; }
unsigned int t_u32_max(void) { return 0xFFFFFFFFu; }
signed char t_s8(void) { return -2; }
/* Zehn Parameter, ein double vorn: neun Ganzzahlen, davon zwei auf dem Stapel
 * (x0..x7 voll), der double in d0. Gewichte 1..9 machen jede Lage sichtbar. */
double t_viele(double f, long a, long b, long c, long d, long e, long g, long h,
               long i, long j) {
  return f + a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * g + 7 * h + 8 * i + 9 * j;
}
/* Acht doubles: d0..d7 voll, keiner auf dem Stapel. */
double t_acht(double a, double b, double c, double d, double e, double f,
              double g, double h) {
  return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

/* Neun Ganzzahlen: die neunte auf dem Stapel (reine Ganzzahlreihe, der Weg
 * ohne Gleitkommamaske). */
long t_neun_i(long a, long b, long c, long d, long e, long f, long g, long h,
              long i) {
  return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i;
}

/* Das dynamische _start ruft __libc_start_main(main, argc, argv, ...). */
static int t_libc_start_main(int (*m)(int, char **, char **), int argc,
                             char **argv) {
  exit(m(argc, argv, argv + argc + 1));
}

struct sym { const char *name; void *addr; };
static struct sym g_syms[] = {
  {"__libc_start_main", (void *)t_libc_start_main},
  {"pow", (void *)pow},       {"atan2", (void *)atan2},
  {"fabs", (void *)fabs},     {"powf", (void *)powf},
  {"labs", (void *)labs},
  {"t_misch", (void *)t_misch}, {"t_halbf", (void *)t_halbf},
  {"t_fd", (void *)t_fd},       {"t_minus_eins", (void *)t_minus_eins},
  {"t_u32_max", (void *)t_u32_max}, {"t_s8", (void *)t_s8},
  {"t_viele", (void *)t_viele}, {"t_acht", (void *)t_acht},
  {"t_neun_i", (void *)t_neun_i},
  {0, 0}};

static void *finde(const char *n) {
  for (int i = 0; g_syms[i].name; i++)
    if (strcmp(g_syms[i].name, n) == 0) return g_syms[i].addr;
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "a64_binder <erzeugnis>\n"); return 96; }
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) { perror("open"); return 96; }
  off_t len = lseek(fd, 0, SEEK_END);
  unsigned char *f = malloc(len);
  if (pread(fd, f, len, 0) != len) { perror("read"); return 96; }
  close(fd);
  Elf64_Ehdr *eh = (Elf64_Ehdr *)f;
  if (memcmp(eh->e_ident, ELFMAG, 4) != 0 || eh->e_machine != EM_AARCH64) {
    fprintf(stderr, "kein arm64-ELF\n"); return 96;
  }
  Elf64_Phdr *ph = (Elf64_Phdr *)(f + eh->e_phoff);
  Elf64_Dyn *dyn = 0;
  for (int i = 0; i < eh->e_phnum; i++) {
    if (ph[i].p_type == PT_LOAD) {
      uint64_t lo = ph[i].p_vaddr & ~0xFFFFULL;
      uint64_t hi = (ph[i].p_vaddr + ph[i].p_memsz + 0xFFFF) & ~0xFFFFULL;
      void *m = mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
      if (m != (void *)lo) { perror("mmap"); return 96; }
      memcpy((void *)ph[i].p_vaddr, f + ph[i].p_offset, ph[i].p_filesz);
    }
  }
  for (int i = 0; i < eh->e_phnum; i++)
    if (ph[i].p_type == PT_DYNAMIC) dyn = (Elf64_Dyn *)ph[i].p_vaddr;
  if (dyn) {
    Elf64_Rela *rela = 0; uint64_t relasz = 0;
    Elf64_Rela *jmp = 0;  uint64_t jmpsz = 0;
    Elf64_Sym *symtab = 0; const char *strtab = 0;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
      if (d->d_tag == DT_RELA) rela = (Elf64_Rela *)d->d_un.d_ptr;
      if (d->d_tag == DT_RELASZ) relasz = d->d_un.d_val;
      if (d->d_tag == DT_JMPREL) jmp = (Elf64_Rela *)d->d_un.d_ptr;
      if (d->d_tag == DT_PLTRELSZ) jmpsz = d->d_un.d_val;
      if (d->d_tag == DT_SYMTAB) symtab = (Elf64_Sym *)d->d_un.d_ptr;
      if (d->d_tag == DT_STRTAB) strtab = (const char *)d->d_un.d_ptr;
    }
    for (int pass = 0; pass < 2; pass++) {
      Elf64_Rela *r = pass ? jmp : rela;
      uint64_t n = (pass ? jmpsz : relasz) / sizeof(Elf64_Rela);
      for (uint64_t k = 0; r && k < n; k++) {
        uint32_t typ = ELF64_R_TYPE(r[k].r_info);
        uint32_t si = ELF64_R_SYM(r[k].r_info);
        if (typ != R_AARCH64_GLOB_DAT && typ != R_AARCH64_JUMP_SLOT &&
            typ != R_AARCH64_ABS64) {
          fprintf(stderr, "Relocation-Typ %u nicht unterstuetzt\n", typ);
          return 98;
        }
        const char *nm = strtab + symtab[si].st_name;
        void *a = finde(nm);
        if (!a) { fprintf(stderr, "unbekanntes Symbol: %s\n", nm); return 97; }
        *(uint64_t *)r[k].r_offset = (uint64_t)a + r[k].r_addend;
      }
    }
  }
  /* Stapel wie vom Kern: argc, argv[], NULL, envp NULL, auxv AT_NULL. */
  size_t ss = 1 << 20;
  uint64_t *st = mmap(0, ss, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  uint64_t *sp = (uint64_t *)((char *)st + ss - 4096);
  sp = (uint64_t *)((uint64_t)sp & ~15ULL);
  sp[0] = 1; sp[1] = (uint64_t)argv[1]; sp[2] = 0; sp[3] = 0; sp[4] = 0; sp[5] = 0;
  uint64_t entry = eh->e_entry;
  __asm__ volatile("mov sp, %0\n br %1\n" ::"r"(sp), "r"(entry) : "memory");
  return 95;
}
