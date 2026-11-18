/* Crystal701 bounded stock rewrite of physical boot block 3.
 * Protocol: PING echo, DRY1 payload check, CMIT, erase, program pages 0..127.
 * Raw page payload is four 1024-byte sectors plus 224-byte OOB.
 * No erase/program occurs until CMIT follows a matching complete dry run.
 * GPL-2.0-or-later. */
.set noreorder
.set noat
.set nomacro
.section .entry,"ax",@progbits
.globl _entry
_entry:
    beq $zero,$zero,start
    nop
    .space 0x3f8,0
.section .text,"ax",@progbits
.globl start,terminal,code_end
start:
    mfc0 $t0,$12,0
    .rept 8
    nop
    .endr
    lui $t1,0xffff
    ori $t1,$t1,0xfffe
    and $t0,$t0,$t1
    mtc0 $t0,$12,0
    .rept 8
    nop
    .endr
    lui $sp,0xb406
    ori $sp,$sp,0x2200
    lui $k0,0xbfc0
    ori $k0,$k0,0x56c4
    jalr $k0
    nop
    /* ROM NAND and DMA setup, as in the verified read loaders. */
    lui $t3,0xb028
    lw $t0,0($t3)
    xori $t0,$t0,0x1e
    sw $t0,0($t3)
    lui $t4,0xb022
    lw $t0,0($t4)
    ori $t0,$t0,2
    sw $t0,0($t4)
    lui $t0,0x0054
    ori $t0,$t0,0x0004
    sw $t0,0x130($t4)       /* SRAM -> NAND FIFO */
    lui $t0,0x1406
    ori $t0,$t0,0x1b00
    sw $t0,0x134($t4)       /* DMA source */
    lui $t0,0x1028
    ori $t0,$t0,0x0010
    sw $t0,0x138($t4)       /* DMA destination */
    /* Clear all 64 status bytes once. */
    lui $t5,0xb406
    ori $t5,$t5,0x1f00
    addu $t6,$t5,$zero
    ori $t7,$zero,16
clear_status:
    sw $zero,0($t6)
    addiu $t6,$t6,4
    addiu $t7,$t7,-1
    bne $t7,$zero,clear_status
    nop
    ori $s0,$zero,0
    ori $s1,$zero,0
    ori $s2,$zero,0
    lui $a0,0x3150          /* WRP1 */
    ori $a0,$a0,0x5257
    jal send_state
    nop
    lui $a1,0xb406
    ori $a1,$a1,0x1b00
    ori $s7,$zero,1
    jal recv_frame
    nop
    lui $t5,0xb406
    lw $t0,0x1b00($t5)
    lui $t1,0x474e          /* PING */
    ori $t1,$t1,0x4950
    bne $t0,$t1,terminal
    nop
    lui $a1,0xb406
    ori $a1,$a1,0x1b00
    ori $a3,$zero,1
    jal usb_send_frames
    nop
    /* Dry-run header: DRY1, target block 3, additive word sum. */
    lui $a1,0xb406
    ori $a1,$a1,0x1b00
    ori $s7,$zero,1
    jal recv_frame
    nop
    lui $t5,0xb406
    ori $t5,$t5,0x1b00
    lw $t0,0($t5)
    lui $t1,0x3159
    ori $t1,$t1,0x5244
    bne $t0,$t1,terminal
    nop
    lw $t0,4($t5)
    ori $t1,$zero,3
    bne $t0,$t1,terminal
    nop
    lw $s3,8($t5)
    lui $a0,0x3159          /* RDY1 */
    ori $a0,$a0,0x4452
    jal send_state
    nop
    ori $s4,$zero,0         /* first pass: receive and checksum only */
pass_start:
    ori $s0,$zero,0
    ori $s1,$zero,0
    ori $s2,$zero,0
sector_loop:
    sltiu $t0,$s1,4
    bne $t0,$zero,data_len
    nop
    ori $s5,$zero,224
    ori $s6,$zero,4
    beq $zero,$zero,receive_sector
    nop
data_len:
    ori $s5,$zero,1024
    ori $s6,$zero,16
receive_sector:
    lui $a1,0xb406
    ori $a1,$a1,0x1b00
    addu $s7,$s6,$zero
frame_loop:
    jal recv_frame
    nop
    addiu $a1,$a1,64
    addiu $s7,$s7,-1
    bne $s7,$zero,frame_loop
    nop
    lui $t5,0xb406
    ori $t5,$t5,0x1b00
    srl $t6,$s5,2
sum_loop:
    lw $t0,0($t5)
    addu $s2,$s2,$t0
    addiu $t5,$t5,4
    addiu $t6,$t6,-1
    bne $t6,$zero,sum_loop
    nop
    beq $s4,$zero,dry_ack
    nop
    /* Start a fresh page only after its first sector was received. */
    bne $s1,$zero,write_sector
    nop
    lui $t3,0xb028
    sll $t0,$s0,0
    addiu $t0,$t0,768     /* block 3, 256 pages/block */
    sw $t0,0x18($t3)
    sw $zero,0x1c($t3)
    lui $t0,0x1000
    sw $t0,0x14($t3)
    ori $t0,$zero,0x80
    sw $t0,0x20($t3)
    ori $t0,$zero,0x6c
    sw $t0,0x24($t3)
    ori $t0,$zero,1
    sw $t0,0x38($t3)
    jal wait_nand
    nop
    bne $v0,$zero,write_fail
    nop
write_sector:
    lui $t3,0xb028
    lui $t4,0xb022
    sll $t0,$s1,10
    lui $t1,0x1000
    or $t0,$t0,$t1
    sw $t0,0x14($t3)
    lw $t0,0x08($t3)
    lui $t1,0xffff
    ori $t1,$t1,0xfcfc
    and $t0,$t0,$t1
    ori $t0,$t0,0x20     /* raw, no ECC or scrambling */
    sw $t0,0x08($t3)
    sw $s5,0x0c($t3)
    sw $s5,0x13c($t4)
    ori $t0,$zero,0x85
    sw $t0,0x20($t3)
    ori $t0,$zero,0x65
    sw $t0,0x24($t3)
    ori $t0,$zero,3      /* random input plus DMA */
    sw $t0,0x38($t3)
    ori $t0,$zero,1
    sw $t0,0x144($t4)
    lui $t1,0x0010
dma_poll:
    lw $t0,0x144($t4)
    andi $t0,$t0,1
    beq $t0,$zero,dma_done
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,dma_poll
    nop
    beq $zero,$zero,write_fail
    nop
dma_done:
    jal wait_nand
    nop
    bne $v0,$zero,write_fail
    nop
    lui $a0,0x574b       /* ACKW */
    ori $a0,$a0,0x4341
    jal send_state
    nop
    sltiu $t0,$s1,4
    bne $t0,$zero,next_sector
    nop
    /* Program confirm and status check. */
    lui $t3,0xb028
    ori $t0,$zero,0x10
    sw $t0,0x20($t3)
    ori $t0,$zero,0x60
    sw $t0,0x24($t3)
    ori $t0,$zero,1
    sw $t0,0x38($t3)
    jal wait_busy
    nop
    bne $v0,$zero,write_fail
    nop
    jal wait_nand
    nop
    bne $v0,$zero,write_fail
    nop
    jal nand_status
    nop
    andi $t0,$v0,0x41
    ori $t1,$zero,0x40
    bne $t0,$t1,write_fail
    nop
    lui $a0,0x4547       /* PAGE */
    ori $a0,$a0,0x4150
    jal send_state
    nop
    beq $zero,$zero,next_sector
    nop
dry_ack:
    lui $a0,0x444b       /* ACKD */
    ori $a0,$a0,0x4341
    jal send_state
    nop
next_sector:
    addiu $s1,$s1,1
    sltiu $t0,$s1,5
    bne $t0,$zero,sector_loop
    nop
    ori $s1,$zero,0
    addiu $s0,$s0,1
    sltiu $t0,$s0,128
    bne $t0,$zero,sector_loop
    nop
    bne $s2,$s3,write_fail
    nop
    bne $s4,$zero,write_complete
    nop
    lui $a0,0x4f59       /* DRYO */
    ori $a0,$a0,0x5244
    jal send_state
    nop
    /* Commit token only after the checked dry run. */
    lui $a1,0xb406
    ori $a1,$a1,0x1b00
    ori $s7,$zero,1
    jal recv_frame
    nop
    lui $t5,0xb406
    ori $t5,$t5,0x1b00
    lw $t0,0($t5)
    lui $t1,0x5449       /* CMIT */
    ori $t1,$t1,0x4d43
    bne $t0,$t1,terminal
    nop
    lw $t0,4($t5)
    ori $t1,$zero,3
    bne $t0,$t1,terminal
    nop
    lw $t0,8($t5)
    bne $t0,$s3,terminal
    nop
    /* Single target erase: block 3. */
    lui $t3,0xb028
    ori $t0,$zero,768
    sw $t0,0x18($t3)
    sw $zero,0x1c($t3)
    lui $t0,0x1000
    sw $t0,0x14($t3)
    ori $t0,$zero,0xd060
    sw $t0,0x20($t3)
    ori $t0,$zero,0x6068
    sw $t0,0x24($t3)
    ori $t0,$zero,1
    sw $t0,0x38($t3)
    jal wait_nand
    nop
    bne $v0,$zero,write_fail
    nop
    jal nand_status
    nop
    andi $t0,$v0,0x41
    ori $t1,$zero,0x40
    bne $t0,$t1,write_fail
    nop
    lui $a0,0x4b4f       /* EROK */
    ori $a0,$a0,0x5245
    jal send_state
    nop
    ori $s4,$zero,1
    beq $zero,$zero,pass_start
    nop
write_complete:
    lui $a0,0x454e       /* DONE */
    ori $a0,$a0,0x4f44
    jal send_state
    nop
    beq $zero,$zero,terminal
    nop
write_fail:
    lui $a0,0x4c49       /* FAIL */
    ori $a0,$a0,0x4146
    jal send_state
    nop
terminal:
    beq $zero,$zero,terminal
    nop

/* NAND status 70h; v0 returns status byte. */
nand_status:
    lui $t3,0xb028
    sw $zero,0x14($t3)
    sw $zero,0x18($t3)
    sw $zero,0x1c($t3)
    lw $t0,0x08($t3)
    lui $t1,0xffff
    ori $t1,$t1,0xff8f
    and $t0,$t0,$t1
    sw $t0,0x08($t3)
    ori $t0,$zero,1
    sw $t0,0x0c($t3)
    ori $t0,$zero,0x70
    sw $t0,0x20($t3)
    ori $t0,$zero,0x61
    sw $t0,0x24($t3)
    ori $t0,$zero,1
    sw $t0,0x38($t3)
    lui $t1,0x0010
status_poll:
    lw $t0,0x04($t3)
    andi $t0,$t0,0x10
    bne $t0,$zero,status_ready
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,status_poll
    nop
    ori $v0,$zero,1
    jr $ra
    nop
status_ready:
    lw $v0,0x10($t3)
    andi $v0,$v0,0xff
    jr $ra
    nop

/* v0=0 when the NAND operation has finished, 1 on timeout. */
wait_busy:
    lui $t3,0xb028
    lui $t1,0x0200
busy_poll:
    lw $t0,0x04($t3)
    bltz $t0,busy_seen
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,busy_poll
    nop
    ori $v0,$zero,1
    jr $ra
    nop
busy_seen:
    addu $v0,$zero,$zero
    jr $ra
    nop

wait_nand:
    lui $t3,0xb028
    lui $t1,0x0200
wait_controller:
    lw $t0,0x04($t3)
    andi $t2,$t0,0x08
    bne $t2,$zero,wait_array
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,wait_controller
    nop
    ori $v0,$zero,1
    jr $ra
    nop
wait_array:
    lui $t1,0x0200
array_poll:
    lw $t0,0x04($t3)
    bgez $t0,array_ready
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,array_poll
    nop
    ori $v0,$zero,1
    jr $ra
    nop
array_ready:
    addu $v0,$zero,$zero
    jr $ra
    nop

/* Receives one 64-byte USB OUT frame into a1, preserving a1. */
recv_frame:
    lui $t2,0xb029
    sltiu $t0,$s7,2
    xori $t0,$t0,1
    sb $t0,0x0b($t2)
    lui $t1,0x0100
recv_poll:
    lbu $t0,0x0b($t2)
    andi $t0,$t0,2
    beq $t0,$zero,recv_copy
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,recv_poll
    nop
    beq $zero,$zero,terminal
    nop
recv_copy:
    addu $t6,$a1,$zero
    ori $t5,$zero,16
recv_word:
    lw $t0,0x84($t2)
    sw $t0,0($t6)
    addiu $t6,$t6,4
    addiu $t5,$t5,-1
    bne $t5,$zero,recv_word
    nop
    jr $ra
    nop

/* a0 magic; status includes page, sector and running checksum. */
send_state:
    addiu $sp,$sp,-4
    sw $ra,0($sp)
    lui $a1,0xb406
    ori $a1,$a1,0x1f00
    sw $a0,0($a1)
    sw $s0,4($a1)
    sw $s1,8($a1)
    sw $s2,12($a1)
    ori $a3,$zero,1
    jal usb_send_frames
    nop
    lw $ra,0($sp)
    addiu $sp,$sp,4
    jr $ra
    nop

/* a1 points to 64-byte frames, a3 count. */
usb_send_frames:
    lui $t2,0xb029
send_frame:
    lui $t1,0x0010
send_pre_poll:
    lbu $t0,0x17($t2)
    andi $t0,$t0,2
    beq $t0,$zero,send_copy
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,send_pre_poll
    nop
    beq $zero,$zero,terminal
    nop
send_copy:
    ori $t5,$zero,16
send_word:
    lw $t6,0($a1)
    sw $t6,0x88($t2)
    addiu $a1,$a1,4
    addiu $t5,$t5,-1
    bne $t5,$zero,send_word
    nop
    ori $t0,$zero,64
    sb $t0,0x14($t2)
    sb $zero,0x15($t2)
    sb $zero,0x17($t2)
    lui $t1,0x0010
send_post_poll:
    lbu $t0,0x17($t2)
    andi $t0,$t0,2
    beq $t0,$zero,send_next
    nop
    addiu $t1,$t1,-1
    bne $t1,$zero,send_post_poll
    nop
    beq $zero,$zero,terminal
    nop
send_next:
    addiu $a3,$a3,-1
    bne $a3,$zero,send_frame
    nop
    jr $ra
    nop
code_end:
