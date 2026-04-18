● Bash(./lyxc examples/test_poke_zero.lyx -o /tmp/test_poke_zero 2>/dev/null; /tmp/test_poke_zero; echo "exit: $?")
  ⎿  Lyx Compiler v0.6.0-aerospace                                                        
     DO-178C TQL-5 Qualified
     Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.                                                                                                                                                                               
     … +33 lines (ctrl+o to expand)                                                       
                                                                                                                                                                                                                                             
  Searched for 3 patterns, read 1 file (ctrl+o to expand)                                                                                                                                                                                    
                                                                                          
● Let me disassemble the crashed binary to see the actual machine code:                                                                                                                                                                      
                                                                                                                                                                                                                                             
● Bash(objdump -d /tmp/test_poke_zero 2>/dev/null | grep -A 50 "<test1>:")                                                                                                                                                                   
  ⎿  No matches found                                                                                                                                                                                                                        
                                                                                                                                                                                                                                             
● Bash(objdump -d /tmp/test_poke_zero 2>/dev/null | head -80)                                                                                                                                                                                
  ⎿  /tmp/test_poke_zero:     Dateiformat elf64-x86-64                                                                                                                                                                                       
     … +56 lines (ctrl+o to expand)                                                                                                                                                                                                          
                                                                                                                                                                                                                                             
● Bash(objdump -d /tmp/test_poke_zero 2>/dev/null | grep -A 40 "401130\|401120\|401140")  
  ⎿    401130:  48 89 45 f0             mov    %rax,-0x10(%rbp)                                                                                                                                                                              
       401134:  48 b8 10 00 00 00 00    movabs $0x10,%rax                                                                                                                                                                                    
       40113b:  00 00 00                                                                                                                                                                                                                     
     … +38 lines (ctrl+o to expand)                                                                                                                                                                                                          
                                                                                                                                                                                                                                             
● Bash(objdump -d /tmp/test_poke_zero 2>/dev/null | tail -100)                                                                                                                                                                               
  ⎿    40117a:  48 8b 7d f0             mov    -0x10(%rbp),%rdi                           
       40117e:  48 8b 75 e8             mov    -0x18(%rbp),%rsi                                                                                                                                                                              
       401182:  48 8b 55 e0             mov    -0x20(%rbp),%rdx                                                                                                                                                                              
     … +53 lines (ctrl+o to expand)                                                       
                                                                                                                                                                                                                                             
  Searched for 1 pattern (ctrl+o to expand)                                                                                                                                                                                                  
                                                                                          
❯ Bitte schreibe Deine Erketnisse in eine audio-bug.md. Wir müssen zum Ende kommen                                                                                                                                                           
                                                                                                                                                                                                                                             
  Read 1 file (ctrl+o to expand)                                                                                                                                                                                                           
                                                                                                                                                                                                                                             
● Found the bug! irAdd uses fn.LocalCount + Src2 = -1 + 2 = 1, loading the wrong slot. Let me find where irAdd is lowered for dst + 0:
