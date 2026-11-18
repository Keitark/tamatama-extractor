/* Crystal701 read-only boot-area reader. GPL-2.0-or-later.
 * Streams the first four physical blocks (1024 pages, 4 MiB) via SRAM.
 * No NAND program, erase, reset, or write-enable opcode is present. */
.set noreorder
.set noat
.set nomacro
.section .entry,"ax",@progbits
.globl _entry
_entry:
    beq $zero, $zero, start
    nop
    .space 0x3f8, 0

.section .text,"ax",@progbits
.globl start, terminal, pre_poll, post_poll, send_response, code_end
.globl status_read, status_write, prid_read, config0_read, config1_read, config2_read, config3_read
.globl initialize_owned, pattern_store, sample_copy, sample_words, sample_after, response_done, transmit
start:
status_read:
    mfc0 $t0, $12, 0
    .rept 8
    nop
    .endr
    addu $s6, $t0, $zero
    addu $s7, $sp, $zero
    lui $t1, 0xffff
    ori $t1, $t1, 0xfffe
    and $t0, $t0, $t1
status_write:
    mtc0 $t0, $12, 0
    .rept 8
    nop
    .endr
prid_read:
    mfc0 $s0, $15, 0
    .rept 8
    nop
    .endr
config0_read:
    mfc0 $s1, $16, 0
    .rept 8
    nop
    .endr
    ori $s2, $zero, 0
    ori $s3, $zero, 0
    ori $s4, $zero, 0
    ori $s5, $zero, 3
    bgez $s1, initialize_owned
    nop
config1_read:
    mfc0 $s2, $16, 1
    .rept 8
    nop
    .endr
    ori $s5, $s5, 4
    bgez $s2, initialize_owned
    nop
config2_read:
    mfc0 $s3, $16, 2
    .rept 8
    nop
    .endr
    ori $s5, $s5, 8
    bgez $s3, initialize_owned
    nop
config3_read:
    mfc0 $s4, $16, 3
    .rept 8
    nop
    .endr
    ori $s5, $s5, 16
initialize_owned:
    /* ROM NAND pin/clock setup; use loader BCH24+UDAT4+descramble settings
       observed in actions-hacking, then perform 00h-30h / 05h-E0h read. */
    lui $sp, 0xb406
    ori $sp, $sp, 0x2100
    lui $k0, 0xbfc0
    ori $k0, $k0, 0x56c4
    jalr $k0
    nop
    lui $t3, 0xb028
    /* The preceding live probe measured CTL low bits 0x03 after ROM setup.
       Convert them to 0x1d, matching actions-hacking NAND_controller_init,
       while preserving the observed upper bits. */
    lw $t0, 0($t3)
    xori $t0, $t0, 0x1e
    sw $t0, 0($t3)
    sw $zero, 0x18($t3)
    sw $zero, 0x1c($t3)
    lw $t0, 0x08($t3)
    lui $t1, 0xffff
    ori $t1, $t1, 0xfc8c
    and $t0, $t0, $t1
    ori $t0, $t0, 0x121
    sw $t0, 0x08($t3)
    ori $t0, $zero, 1024
    sw $t0, 0x0c($t3)
    /* DMA channel 1: NAND FIFO physical 0x10280010 to SRAM 0x14061a00. */
    lui $t4, 0xb022
    lw $t0, 0($t4)
    ori $t0, $t0, 2
    sw $t0, 0($t4)
    lui $t0, 0x0004
    ori $t0, $t0, 0x0054
    sw $t0, 0x130($t4)
    lui $t0, 0x1028
    ori $t0, $t0, 0x0010
    sw $t0, 0x134($t4)
    ori $gp, $zero, 0
    ori $a2, $zero, 0
    ori $k1, $zero, 0
    ori $v0, $zero, 0
sector_read:
    sw $a2, 0x18($t3)  /* physical row/page */
    /* Column = 1024*i; OOB column = 4096 + 46*i (BCH24 + 4 user bytes). */
    sll $t0, $gp, 10
    sll $t1, $gp, 5
    sll $t2, $gp, 4
    addu $t1, $t1, $t2
    sll $t2, $gp, 1
    subu $t1, $t1, $t2
    addiu $t1, $t1, 4096
    sll $t1, $t1, 16
    or $t0, $t0, $t1
    sw $t0, 0x14($t3)
    lui $t0, 0x1406
    ori $t0, $t0, 0x1a00
    sw $t0, 0x138($t4)
    ori $t0, $zero, 1024
    sw $t0, 0x13c($t4)
    ori $t0, $zero, 0x3000
    sw $t0, 0x20($t3)
    ori $t0, $zero, 0x626c
    sw $t0, 0x24($t3)
    ori $t0, $zero, 1
    sw $t0, 0x38($t3)
    lui $t1, 1
nand_page_poll:
    lw $t0, 0x04($t3)
    andi $t0, $t0, 0x08
    bne $t0, $zero, nand_page_ready
    nop
    addiu $t1, $t1, -1
    bne $t1, $zero, nand_page_poll
    nop
nand_page_ready:
    ori $fp, $zero, 0
    beq $t1, $zero, report_read
    nop
    ori $fp, $fp, 1
    /* Allow the NAND array transfer to settle before random-data read. */
    lui $t1, 2
nand_array_delay:
    addiu $t1, $t1, -1
    bne $t1, $zero, nand_array_delay
    nop
    lui $t0, 0xe005
    ori $t0, $t0, 0xe005
    sw $t0, 0x20($t3)
    lui $t0, 0x7174
    ori $t0, $t0, 0x6164
    sw $t0, 0x24($t3)
    nor $t0, $zero, $zero
    sw $t0, 0x4c($t3)
    sw $t0, 0x50($t3)
    ori $t0, $zero, 0x1d
    sw $t0, 0x38($t3)
    sw $t0, 0x144($t4)
    lui $t1, 1
nand_dma_poll:
    lw $t0, 0x144($t4)
    andi $t0, $t0, 1
    beq $t0, $zero, nand_dma_done
    nop
    addiu $t1, $t1, -1
    bne $t1, $zero, nand_dma_poll
    nop
    beq $zero, $zero, report_read
    nop
nand_dma_done:
    ori $fp, $fp, 2
report_read:
    lui $t2, 0xb406
    ori $t2, $t2, 0x1e00
    sw $fp, 0($t2)
    lw $t0, 0x04($t3)
    sw $t0, 4($t2)
    lw $t0, 0x3c($t3)
    sw $t0, 8($t2)
    lw $t0, 0x144($t4)
    sw $t0, 12($t2)
    bne $v0, $zero, after_read
    nop
    lui $t5, 0xb406
    ori $t5, $t5, 0x19d8
    lui $t8, 0xa65c
    ori $t8, $t8, 0x39d2
    lui $t9, 0x5aa5
    ori $t9, $t9, 0xc33c
    sw $t8, 0($t5)
    sw $t9, 36($t5)
    addiu $a0, $t5, 4
    ori $t6, $zero, 0
pattern_store:
    sb $t6, 0($a0)
    addiu $t6, $t6, 1
    addiu $a0, $a0, 1
    sltiu $t7, $t6, 32
    bne $t7, $zero, pattern_store
    nop
    lui $a1, 0xb406
    ori $a1, $a1, 0x1a00
    beq $zero, $zero, transmit
    nop
after_read:
    lui $a1, 0xb406
    ori $a1, $a1, 0x1a00
    beq $zero, $zero, advance_sample
    nop
transmit:
    lui $t2, 0xb029
    lui $t3, 0x0010
pre_poll:
    lbu $t4, 0x17($t2)
    andi $t4, $t4, 2
    beq $t4, $zero, send_response
    nop
    addiu $t3, $t3, -1
    bne $t3, $zero, pre_poll
    nop
    beq $zero, $zero, terminal
    nop
send_response:
    .include "identity.inc"
    beq $v0, $zero, payload_words
    nop
    sw $v0, 0x88($t2)
    sw $v1, 0x88($t2)
    addu $t6, $a1, $zero
    sw $t6, 0x88($t2)
    ori $t6, $zero, 16
    sw $t6, 0x88($t2)
payload_words:
    sw $s0, 0x88($t2)
    sw $s1, 0x88($t2)
    sw $s2, 0x88($t2)
    sw $s3, 0x88($t2)
    bne $v0, $zero, payload_done
    nop
    sw $s4, 0x88($t2)
    sw $s5, 0x88($t2)
    sw $s6, 0x88($t2)
    sw $s7, 0x88($t2)
payload_done:
    ori $t0, $zero, 64
commit_response:
    sb $t0, 0x14($t2)
    sb $zero, 0x15($t2)
    sb $zero, 0x17($t2)
    lui $t3, 0x0010
post_poll:
    lbu $t4, 0x17($t2)
    andi $t4, $t4, 2
    beq $t4, $zero, response_done
    nop
    addiu $t3, $t3, -1
    bne $t3, $zero, post_poll
    nop
terminal:
    beq $zero, $zero, terminal
    nop
response_done:
    beq $v0, $zero, advance_sample
    nop
    beq $v1, $zero, terminal
    nop
    ori $t6, $zero, 65
    beq $k1, $t6, next_sector
    nop
    addiu $a1, $a1, 16
    ori $t6, $zero, 64
    bne $k1, $t6, advance_sample
    nop
    lui $a1, 0xb406
    ori $a1, $a1, 0x1e00
    beq $zero, $zero, advance_sample
    nop
next_sector:
    addiu $gp, $gp, 1
    sltiu $t6, $gp, 4
    bne $t6, $zero, next_read
    nop
    ori $gp, $zero, 0
    addiu $a2, $a2, 1
    sltiu $t6, $a2, 1024
    beq $t6, $zero, terminal
    nop
next_read:
    ori $k1, $zero, 0
    lui $t3, 0xb028
    lui $t4, 0xb022
    beq $zero, $zero, sector_read
    nop
advance_sample:
    addiu $v0, $v0, 1
    addiu $k1, $k1, 1
sample_copy:
    lw $t6, 0($t5)
    xor $v1, $t6, $t8
    lw $t6, 36($t5)
    xor $t6, $t6, $t9
    or $v1, $v1, $t6
sample_words:
    lw $s0, 0($a1)
    lw $s1, 4($a1)
    lw $s2, 8($a1)
    lw $s3, 12($a1)
sample_after:
    lw $t6, 0($t5)
    xor $t6, $t6, $t8
    or $v1, $v1, $t6
    lw $t6, 36($t5)
    xor $t6, $t6, $t9
    or $v1, $v1, $t6
    sltiu $v1, $v1, 1
    beq $zero, $zero, transmit
    nop
code_end:
