/* Crystal701 faster read-only raw NAND stream, including 224-byte OOB per page.
 * Derived from the controller sequence in actions-hacking/common/nand.c.
 * NAND commands present: page read 00h-30h and random read 05h-E0h only.
 * No page program, block erase, reset, or write-enable command is present.
 * GPL-2.0-or-later. */
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
.globl start, terminal, code_end
start:
    mfc0 $t0, $12, 0
    .rept 8
    nop
    .endr
    lui $t1, 0xffff
    ori $t1, $t1, 0xfffe
    and $t0, $t0, $t1
    mtc0 $t0, $12, 0
    .rept 8
    nop
    .endr
    lui $sp, 0xb406
    ori $sp, $sp, 0x2100
    lui $k0, 0xbfc0
    ori $k0, $k0, 0x56c4
    jalr $k0
    nop

    /* ROM setup leaves NAND_CTL low bits 0x03 on this device. */
    lui $t3, 0xb028
    lw $t0, 0($t3)
    xori $t0, $t0, 0x1e
    sw $t0, 0($t3)
    /* DMA channel 1, NAND FIFO to the already tested SRAM buffer. */
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
    lui $t0, 0x1406
    ori $t0, $t0, 0x1a00
    sw $t0, 0x138($t4)

    lui $s0, 0x0000              /* RAW_START_ROW_HI */
    ori $s0, $s0, 0x0000         /* RAW_START_ROW_LO */
    lui $s2, 0x0010              /* end page, exclusive: 1,048,576 */
    ori $s3, $zero, 0             /* status sequence */
    /* A 64-byte status record; its last eight words stay zero. */
    lui $t5, 0xb406
    ori $t5, $t5, 0x1e00
    addu $t6, $t5, $zero
    ori $t7, $zero, 16
clear_status:
    sw $zero, 0($t6)
    addiu $t6, $t6, 4
    addiu $t7, $t7, -1
    bne $t7, $zero, clear_status
    nop
    lui $t0, 0x3157              /* "RAW1" in little endian */
    ori $t0, $t0, 0x4152
    sw $t0, 0($t5)
    sw $s0, 4($t5)
    nor $t0, $zero, $zero         /* hello sector = 0xffffffff */
    sw $t0, 8($t5)
    sw $s2, 16($t5)              /* total physical pages */
    ori $t0, $zero, 4320
    sw $t0, 24($t5)              /* raw bytes per page */
    addu $a1, $t5, $zero
    ori $a3, $zero, 1
    jal usb_send_frames
    nop

page_loop:
    ori $s1, $zero, 0
sector_loop:
    lui $t3, 0xb028
    lui $t4, 0xb022
    sw $s0, 0x18($t3)
    sw $zero, 0x1c($t3)
    sltiu $t0, $s1, 4
    bne $t0, $zero, data_sector
    nop
    lui $t0, 0x1000              /* OOB column 4096 */
    sw $t0, 0x14($t3)
    ori $s5, $zero, 224
    ori $s6, $zero, 4             /* four 64-byte USB packets */
    ori $s7, $zero, 0x6174       /* alternate column for OOB */
    beq $zero, $zero, sector_configured
    nop
data_sector:
    sll $t0, $s1, 10
    lui $t1, 0x1000
    or $t0, $t0, $t1
    sw $t0, 0x14($t3)
    ori $s5, $zero, 1024
    ori $s6, $zero, 16
    ori $s7, $zero, 0x6164
sector_configured:
    lw $t0, 0x08($t3)
    lui $t1, 0xffff
    ori $t1, $t1, 0xfc8c
    and $t0, $t0, $t1
    ori $t0, $t0, 0x20          /* raw: no ECC or descrambling */
    sw $t0, 0x08($t3)
    sw $s5, 0x0c($t3)
    sw $s5, 0x13c($t4)
    ori $t0, $zero, 0x3000     /* 00h-30h page read */
    sw $t0, 0x20($t3)
    ori $t0, $zero, 0x626c
    sw $t0, 0x24($t3)
    ori $t0, $zero, 1
    sw $t0, 0x38($t3)
    ori $s4, $zero, 0
    lui $t1, 1
page_poll:
    lw $t0, 0x04($t3)
    andi $t0, $t0, 0x08
    bne $t0, $zero, page_ready
    nop
    addiu $t1, $t1, -1
    bne $t1, $zero, page_poll
    nop
    beq $zero, $zero, report_read
    nop
page_ready:
    ori $s4, $s4, 1
    ori $t1, $zero, 8192      /* >=50 us settling; shorter than slow reader */
array_delay:
    addiu $t1, $t1, -1
    bne $t1, $zero, array_delay
    nop
    ori $t0, $zero, 0xe005     /* 05h-E0h random data read */
    sw $t0, 0x20($t3)
    sw $s7, 0x24($t3)
    ori $t0, $zero, 1
    sw $t0, 0x38($t3)
    sw $t0, 0x144($t4)
    lui $t1, 1
dma_poll:
    lw $t0, 0x144($t4)
    andi $t0, $t0, 1
    beq $t0, $zero, dma_done
    nop
    addiu $t1, $t1, -1
    bne $t1, $zero, dma_poll
    nop
    beq $zero, $zero, report_read
    nop
dma_done:
    ori $s4, $s4, 2
report_read:
    addiu $s3, $s3, 1
    lui $t5, 0xb406
    ori $t5, $t5, 0x1e00
    sw $s0, 4($t5)
    sw $s1, 8($t5)
    sw $s4, 12($t5)
    lw $t0, 0x04($t3)
    sw $t0, 16($t5)
    lw $t0, 0x144($t4)
    sw $t0, 20($t5)
    sw $s5, 24($t5)
    sw $s3, 28($t5)
    lui $a1, 0xb406
    ori $a1, $a1, 0x1a00
    addu $a3, $s6, $zero
    jal usb_send_frames
    nop
    lui $a1, 0xb406
    ori $a1, $a1, 0x1e00
    ori $a3, $zero, 1
    jal usb_send_frames
    nop
    addiu $s1, $s1, 1
    sltiu $t0, $s1, 5
    bne $t0, $zero, sector_loop
    nop
    addiu $s0, $s0, 1
    sltu $t0, $s0, $s2
    bne $t0, $zero, page_loop
    nop
terminal:
    beq $zero, $zero, terminal
    nop

/* a1 points to 64-byte frames; a3 is the frame count. */
usb_send_frames:
    lui $t2, 0xb029
usb_frame:
    lui $t1, 0x0010
usb_pre_poll:
    lbu $t0, 0x17($t2)
    andi $t0, $t0, 2
    beq $t0, $zero, usb_copy
    nop
    addiu $t1, $t1, -1
    bne $t1, $zero, usb_pre_poll
    nop
    beq $zero, $zero, terminal
    nop
usb_copy:
    ori $t5, $zero, 16
usb_word:
    lw $t6, 0($a1)
    sw $t6, 0x88($t2)
    addiu $a1, $a1, 4
    addiu $t5, $t5, -1
    bne $t5, $zero, usb_word
    nop
    ori $t0, $zero, 64
    sb $t0, 0x14($t2)
    sb $zero, 0x15($t2)
    sb $zero, 0x17($t2)
    lui $t1, 0x0010
usb_post_poll:
    lbu $t0, 0x17($t2)
    andi $t0, $t0, 2
    beq $t0, $zero, usb_next
    nop
    addiu $t1, $t1, -1
    bne $t1, $zero, usb_post_poll
    nop
    beq $zero, $zero, terminal
    nop
usb_next:
    addiu $a3, $a3, -1
    bne $a3, $zero, usb_frame
    nop
    jr $ra
    nop
code_end:
