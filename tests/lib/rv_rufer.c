/*
 * tests/lib/rv_rufer.c — C ruft Lyx auf riscv64, und prueft danach die
 * callee-saved Register (#2140).
 *
 * Der riscv-Codegen benutzt s11 (x27) als Hilfsregister fuer Versaetze
 * jenseits von zwoelf Bit (RV_WEIT, #2061). Nach dem psABI muss eine Funktion
 * s0..s11 unveraendert zurueckgeben. Unter Lyx-Aufrufern faellt ein Verstoss
 * nie auf — keiner haelt dort etwas in s11 —, erst ein C-Aufrufer verliert
 * seinen Wert. Genau den spielt dieses Programm:
 *
 *   - das statische riscv-Erzeugnis an seine feste Adresse legen,
 *   - aus AUIPC+JALR im _start-Rumpf (Offset 12, #2271) die Adresse von
 *     main lesen,
 *   - main als C-Funktion rufen, mit Merkwerten in s1..s11,
 *   - die Werte danach vergleichen.
 *
 * Ausgabe: "ret=<Rueckgabe von main> verloren=<Liste der veraenderten>".
 * Mit dem NDK statisch gegen bionic gebaut; laeuft unter qemu-user.
 */
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* rufe(fn, merk, nachher): s1..s11 := merk+1..merk+11, fn() rufen, die
 * Registerwerte danach in nachher[0..10] ablegen; Rueckgabe = a0 von fn. */
long rufe(long fn, long merk, long *nachher);
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
    "  jalr ra, 0(a0)\n"
    "  ld t0, 104(sp)\n"
    "  sd s1, 0(t0)\n  sd s2, 8(t0)\n  sd s3, 16(t0)\n  sd s4, 24(t0)\n"
    "  sd s5, 32(t0)\n  sd s6, 40(t0)\n  sd s7, 48(t0)\n  sd s8, 56(t0)\n"
    "  sd s9, 64(t0)\n  sd s10, 72(t0)\n  sd s11, 80(t0)\n"
    "  ld ra, 0(sp)\n  ld s0, 8(sp)\n  ld s1, 16(sp)\n  ld s2, 24(sp)\n"
    "  ld s3, 32(sp)\n  ld s4, 40(sp)\n  ld s5, 48(sp)\n  ld s6, 56(sp)\n"
    "  ld s7, 64(sp)\n  ld s8, 72(sp)\n  ld s9, 80(sp)\n  ld s10, 88(sp)\n"
    "  ld s11, 96(sp)\n"
    "  addi sp, sp, 112\n  ret\n");

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "rv_rufer <erzeugnis>\n"); return 96; }
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) { perror("open"); return 96; }
  off_t len = lseek(fd, 0, SEEK_END);
  unsigned char *f = malloc(len);
  if (pread(fd, f, len, 0) != len) { perror("read"); return 96; }
  close(fd);
  Elf64_Ehdr *eh = (Elf64_Ehdr *)f;
  if (memcmp(eh->e_ident, ELFMAG, 4) != 0 || eh->e_machine != EM_RISCV) {
    fprintf(stderr, "kein riscv-ELF\n"); return 96;
  }
  Elf64_Phdr *ph = (Elf64_Phdr *)(f + eh->e_phoff);
  for (int i = 0; i < eh->e_phnum; i++) {
    if (ph[i].p_type != PT_LOAD) continue;
    uint64_t lo = ph[i].p_vaddr & ~0xFFFULL;
    uint64_t hi = (ph[i].p_vaddr + ph[i].p_memsz + 0xFFF) & ~0xFFFULL;
    void *m = mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (m != (void *)lo) { perror("mmap"); return 96; }
    memcpy((void *)ph[i].p_vaddr, f + ph[i].p_offset, ph[i].p_filesz);
  }
  /* AUIPC ra, hi / JALR ra, lo(ra) bei e_entry + 12 (rlb_emitStart, #2271). */
  uint32_t auipc = *(uint32_t *)(eh->e_entry + 12);
  uint32_t jalr = *(uint32_t *)(eh->e_entry + 16);
  if ((auipc & 0x7F) != 0x17 || (jalr & 0x7F) != 0x67) {
    fprintf(stderr, "kein AUIPC+JALR bei _start+12\n"); return 98;
  }
  int64_t hi = (int64_t)(int32_t)(auipc & 0xFFFFF000u);
  int64_t lo = (int64_t)((int32_t)jalr >> 20);
  long mainVA = (long)(eh->e_entry + 12 + hi + lo);
  long nachher[11];
  long merk = 0x5100;
  long r = rufe(mainVA, merk, nachher);
  printf("ret=%ld verloren=", r);
  int n = 0;
  for (int i = 0; i < 11; i++)
    if (nachher[i] != merk + i + 1) { printf("%ss%d", n ? "," : "", i + 1); n++; }
  if (!n) printf("-");
  printf("\n");
  return 0;
}
